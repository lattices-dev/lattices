import assert from "node:assert/strict";
import { accessSync, rmSync } from "node:fs";
import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";

import type { AgentLayerState } from "@action/protocol";

import { AgentLayerDirector, agentLayerRouting, parseAgentLayerOpen, type AgentLayerDisplayState } from "./agent-layer.js";

function stateFor(pid: number): AgentLayerState {
  return {
    pid,
    displayId: 7,
    bounds: { x: 5000, y: 0, width: 1280, height: 800 },
    pip: true,
    windows: [{
      pid: 900,
      bundleId: "com.apple.calculator",
      title: "Calculator",
      original: { x: 100, y: 100, width: 230, height: 400 },
    }],
    startedAt: "2026-09-29T12:00:00.000Z",
  };
}

async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

/**
 * A fake native host. `agent-layer` "starts" a process (a pid in `live`), writes the state
 * file the way the native command does, and exits when the stop file appears.
 */
async function fixture(options: {
  stopExits?: boolean; writeState?: boolean; prepared?: boolean; terminateExits?: boolean; writeDisplayState?: boolean;
  sessionDisplayId?: number; sessionStatePid?: number; invalidateDisplayOnOpen?: boolean; malformedReply?: boolean;
} = {}) {
  const root = await mkdtemp(join(tmpdir(), "action-agent-layer-"));
  const live = new Set<number>();
  const calls: string[][] = [];
  const terminated: number[] = [];
  const owners = new Set<number>();
  const safetyPath = join(root, "isolation-block.json");
  let nextPid = 5000;
  let director: AgentLayerDirector;

  const isAlive = (pid: number) => {
    if (live.has(pid) && options.stopExits !== false) {
      // Stop file present → the native process restores windows, deletes state, exits.
      const stop = owners.has(pid) ? director.paths().displayStop : director.paths().stop;
      try {
        accessSync(stop);
        live.delete(pid);
        rmSync(owners.has(pid) ? director.paths().displayState : director.paths().state, { force: true });
      } catch {
        // Still running.
      }
    }
    return live.has(pid);
  };

  director = new AgentLayerDirector("/unused", {
    root,
    isAlive,
    terminate: (pid) => {
      terminated.push(pid);
      if (options.terminateExits !== false) live.delete(pid);
    },
    safetyPath,
    stateWaitMs: 200,
    closeWaitMs: 120,
    runHost: async (args) => {
      calls.push(args);
      const pid = nextPid++;
      live.add(pid);
      if (args[0] === "agent-display") {
        owners.add(pid);
        if (options.writeDisplayState !== false) {
          await writeFile(director.paths().displayState, JSON.stringify(displayFor(pid,
            Number(args[args.indexOf("--width") + 1]), Number(args[args.indexOf("--height") + 1]))));
        }
        return { stdout: JSON.stringify({ status: "agent-display-running", detail: String(pid) }) };
      }
      if (options.writeState !== false) {
        const stateFile = args[args.indexOf("--state-file") + 1];
        const display = JSON.parse(await readFile(director.paths().displayState, "utf8")) as AgentLayerDisplayState;
        const state = stateFor(pid);
        if (options.sessionDisplayId !== undefined) state.displayId = options.sessionDisplayId;
        if (options.sessionStatePid !== undefined) {
          state.pid = options.sessionStatePid;
          live.add(options.sessionStatePid);
        }
        state.bounds.width = display.width;
        state.bounds.height = display.height;
        state.startedAt = new Date(Date.parse(state.startedAt) + pid).toISOString();
        await writeFile(stateFile, JSON.stringify(state));
      }
      if (options.invalidateDisplayOnOpen) await rm(director.paths().displayState);
      return { stdout: options.malformedReply ? "invalid JSON" : JSON.stringify({ status: "agent-layer-running", detail: String(pid) }) };
    },
  });
  if (options.prepared !== false) {
    live.add(4000);
    owners.add(4000);
    await writeFile(director.paths().displayState, JSON.stringify(displayFor(4000)));
  }
  return { root, director, live, calls, terminated, safetyPath, cleanup: () => rm(root, { recursive: true, force: true }) };
}

function displayFor(pid: number, width = 1280, height = 800): AgentLayerDisplayState {
  return { schemaVersion: 1, pid, displayId: 7, startedAt: "2026-09-29T11:00:00.000Z", width, height, serialNumber: 0x41435401 };
}

describe("parseAgentLayerOpen", () => {
  test("defaults to a caller-owned layer with no size", () => {
    assert.deepEqual(parseAgentLayerOpen({}), { owner: "caller" });
  });

  test("accepts CLI-shaped strings", () => {
    assert.deepEqual(
      parseAgentLayerOpen({ bundleId: "com.apple.calculator", width: "1280", height: "800", pip: "off", owner: "detached" }),
      { bundleId: "com.apple.calculator", width: 1280, height: 800, pip: false, owner: "detached" },
    );
  });

  test("narrows to one window by id or title", () => {
    assert.deepEqual(parseAgentLayerOpen({ bundleId: "com.google.Chrome", windowId: "4821", windowTitle: " New Issue " }), {
      bundleId: "com.google.Chrome",
      windowId: 4821,
      windowTitle: "New Issue",
      owner: "caller",
    });
    assert.throws(() => parseAgentLayerOpen({ windowId: 0 }), /positive integer/);
  });

  test("takes a url for the subject app, and only with one", () => {
    assert.deepEqual(parseAgentLayerOpen({ bundleId: "com.apple.Safari", url: " news.ycombinator.com " }), {
      bundleId: "com.apple.Safari",
      url: "news.ycombinator.com",
      owner: "caller",
    });
    assert.throws(() => parseAgentLayerOpen({ url: "example.com" }), /pass bundleId too/);
    assert.throws(() => parseAgentLayerOpen({ bundleId: "com.apple.Safari", url: "example.com", windowId: 9 }), /can't be combined/);
  });

  test("rejects half a size and a doubled subject", () => {
    assert.throws(() => parseAgentLayerOpen({ width: 1280 }), /width and height go together/);
    assert.throws(() => parseAgentLayerOpen({ bundleId: "a", pid: 3 }), /bundleId or pid/);
    assert.throws(() => parseAgentLayerOpen({ pid: -1 }), /positive integer/);
  });
});

describe("AgentLayerDirector", () => {
  test("open requires an explicitly prepared live display and never hotplugs", async () => {
    const { director, calls, live, cleanup } = await fixture({ prepared: false });
    try {
      await assert.rejects(director.open(), /No prepared agent display.*missing/);
      assert.equal(calls.length, 0);
      await writeFile(director.paths().displayState, JSON.stringify(displayFor(4000)));
      await assert.rejects(director.open(), /No prepared agent display.*stale/);
      assert.equal(calls.length, 0);
      live.add(4000);
      await writeFile(director.paths().displayState, JSON.stringify({ ...displayFor(4000), serialNumber: 0 }));
      await assert.rejects(director.open(), /No prepared agent display.*invalid/);
      assert.equal(calls.length, 0);
    } finally { await cleanup(); }
  });

  test("prepare creates one persistent owner and reuses it without changing topology", async () => {
    const { director, calls, cleanup } = await fixture({ prepared: false });
    try {
      const prepared = await director.prepareDisplay();
      assert.equal(prepared.state, "ready");
      assert.equal(prepared.display?.width, 1440);
      assert.equal(prepared.display?.height, 900);
      assert.equal(calls[0]?.[0], "agent-display");
      assert.equal(calls[0]?.includes("--parent-pid"), false);
      assert.deepEqual(await director.prepareDisplay({ width: "1440", height: "900" }), prepared);
      assert.equal(calls.length, 1);
      await assert.rejects(director.prepareDisplay({ width: 1280, height: 800 }), /release and explicitly prepare/);
      assert.equal(calls.length, 1);
      await assert.rejects(director.prepareDisplay({ width: 639, height: 400 }), /at least 640x400/);
      await assert.rejects(director.prepareDisplay({ width: 640 }), /go together/);
      await assert.rejects(director.prepareDisplay({ width: 8193, height: 900 }), /must not exceed 8192/);
    } finally { await cleanup(); }
  });

  test("quarantine blocks provisioning but an already prepared display can host sessions", async () => {
    const { director, calls, safetyPath, cleanup } = await fixture({ prepared: false });
    try {
      await writeFile(safetyPath, JSON.stringify({ blocked: true, reason: "test quarantine" }));
      await assert.rejects(director.prepareDisplay(), /test quarantine/);
      assert.equal(calls.length, 0);
      await rm(safetyPath);
      await director.prepareDisplay();
      await writeFile(safetyPath, JSON.stringify({ blocked: true, reason: "test quarantine" }));
      const opened = await director.open();
      assert.equal(opened.active, true);
      assert.equal((await director.prepareDisplay()).active, true);
      assert.equal(calls.filter(call => call[0] === "agent-display").length, 1);
      assert.equal(JSON.parse(await readFile(safetyPath, "utf8")).blocked, true);
    } finally { await cleanup(); }
  });

  test("session size mismatch leaves the current session and owner intact", async () => {
    const { director, calls, cleanup } = await fixture();
    try {
      const opened = await director.open();
      await assert.rejects(director.open({ width: 1440, height: 900 }), /Prepared display is 1280x800/);
      assert.equal((await director.status()).layer?.pid, opened.layer?.pid);
      assert.equal(calls.length, 1);
    } finally { await cleanup(); }
  });

  test("release requires explicit task closure before removing the prepared display", async () => {
    const { director, live, terminated, cleanup } = await fixture();
    try {
      const opened = await director.open();
      await assert.rejects(director.releaseDisplay(), /Close the active task explicitly/);
      assert.equal(live.has(opened.layer!.pid), true);
      await director.close();
      const released = await director.releaseDisplay();
      assert.equal(released.state, "missing");
      assert.equal(released.active, false);
      assert.equal(live.has(opened.layer!.pid), false);
      assert.equal(live.has(4000), false);
      assert.deepEqual(terminated, []);
    } finally { await cleanup(); }
  });

  test("release refuses to remove a display while a session cannot close", async () => {
    const { director, live, cleanup } = await fixture({ stopExits: false, terminateExits: false });
    try {
      await director.open();
      await assert.rejects(director.releaseDisplay(), /refusing to release its prepared display/);
      assert.equal(live.has(4000), true);
      assert.equal(await exists(director.paths().displayStop), false);
    } finally { await cleanup(); }
  });

  test("release does not force terminate a prepared owner that ignores its stop request", async () => {
    const { director, live, terminated, cleanup } = await fixture({ stopExits: false });
    try {
      await assert.rejects(director.releaseDisplay(), /No forced display removal/);
      assert.equal(live.has(4000), true);
      assert.deepEqual(terminated, []);
    } finally { await cleanup(); }
  });

  test("queued prepare and open calls keep one display and separate session identities", async () => {
    const { director, calls, cleanup } = await fixture({ prepared: false });
    try {
      const preparation = director.prepareDisplay();
      const opening = director.open();
      await assert.rejects(director.open(), /already has an active task/);
      const [prepared, first] = await Promise.all([preparation, opening]);
      assert.equal(calls.filter(call => call[0] === "agent-display").length, 1);
      assert.equal(first.layer?.displayId, prepared.display?.displayId);
      assert.equal((await director.status()).layer?.pid, first.layer?.pid);
    } finally { await cleanup(); }
  });

  test("a missing display manifest after provisioning remains an explicit failure", async () => {
    const { director, calls, cleanup } = await fixture({ prepared: false, writeDisplayState: false });
    try {
      await assert.rejects(director.prepareDisplay(), /never wrote a live prepared display manifest.*owner PID 5000 may still be running/);
      assert.equal(calls.length, 1);
      await assert.rejects(director.open(), /No prepared agent display/);
      assert.equal(calls.length, 1);
    } finally { await cleanup(); }
  });

  test("a failed session identity check closes only the created session and preserves its display", async () => {
    const { director, live, cleanup } = await fixture({ sessionDisplayId: 8 });
    try {
      await assert.rejects(director.open(), /state does not match.*Created session PID 5000 was closed.*prepared display was retained/);
      assert.deepEqual([...live], [4000]);
      assert.equal((await director.displayStatus()).active, true);
    } finally { await cleanup(); }
  });

  test("display identity loss after session startup cleans up the known session", async () => {
    const { director, live, cleanup } = await fixture({ invalidateDisplayOnOpen: true });
    try {
      await assert.rejects(director.open(), /No prepared agent display.*Created session PID 5000 was closed/);
      assert.deepEqual([...live], [4000]);
    } finally { await cleanup(); }
  });

  test("a replaced session is never closed during failed setup cleanup", async () => {
    const { director, live, terminated, cleanup } = await fixture({ sessionStatePid: 6000 });
    try {
      await assert.rejects(director.open(), /refusing to close a replacement.*PID 5000 may remain running/);
      assert.deepEqual([...live], [4000, 5000, 6000]);
      assert.equal(await exists(director.paths().stop), false);
      assert.deepEqual(terminated, []);
    } finally { await cleanup(); }
  });

  test("a malformed native reply reports uncertain session ownership without stopping the display", async () => {
    const { director, live, cleanup } = await fixture({ malformedReply: true });
    try {
      await assert.rejects(director.open(), /Session ownership is unconfirmed.*prepared display was retained/);
      assert.deepEqual([...live], [4000, 5000]);
      assert.equal((await director.status()).active, true);
    } finally { await cleanup(); }
  });

  test("display manifest validation rejects reserved PIDs and out-of-range native IDs", async () => {
    const { director, cleanup } = await fixture();
    try {
      for (const override of [{ pid: 1 }, { displayId: 0x100000000 }, { serialNumber: 0x100000000 }, { width: 8193 }]) {
        await writeFile(director.paths().displayState, JSON.stringify({ ...displayFor(4000), ...override }));
        assert.equal((await director.displayStatus()).state, "invalid");
      }
    } finally { await cleanup(); }
  });

  test("open launches agent-layer and returns the native state", async () => {
    const { director, calls, cleanup } = await fixture();
    try {
      const status = await director.open({ bundleId: "com.apple.calculator", width: 1280, height: 800, pip: true });
      const args = calls[0] ?? [];
      assert.equal(args[0], "agent-layer");
      assert.equal(args[args.indexOf("--parent-pid") + 1], String(process.pid));
      assert.equal(args[args.indexOf("--bundle-id") + 1], "com.apple.calculator");
      assert.equal(args[args.indexOf("--pip") + 1], "on");
      assert.equal(args[args.indexOf("--display-id") + 1], "7");
      assert.equal(args[args.indexOf("--display-owner-pid") + 1], "4000");
      assert.equal(args[args.indexOf("--display-started-at") + 1], displayFor(4000).startedAt);
      assert.equal(args[args.indexOf("--display-state-file") + 1], director.paths().displayState);
      assert.equal(status.active, true);
      assert.equal(status.layer?.displayId, 7);
      assert.deepEqual(status.subject, { bundleId: "com.apple.calculator" });
      assert.deepEqual(agentLayerRouting(status), {
        bundleId: "com.apple.calculator",
        bounds: { x: 5000, y: 0, width: 1280, height: 800 },
      });
    } finally {
      await cleanup();
    }
  });

  test("a detached layer does not watch this process", async () => {
    const { director, calls, cleanup } = await fixture();
    try {
      await director.open({ pid: 900, owner: "detached" });
      assert.equal(calls[0]?.includes("--parent-pid"), false);
      assert.equal(calls[0]?.[calls[0].indexOf("--pid") + 1], "900");
    } finally {
      await cleanup();
    }
  });

  test("opening again preserves the existing task until explicit close", async () => {
    const { director, live, cleanup } = await fixture();
    try {
      const first = await director.open({ bundleId: "com.apple.calculator" });
      await assert.rejects(director.open({ bundleId: "com.apple.TextEdit" }), /already has an active task/);
      assert.equal(live.has(first.layer!.pid), true);
      await director.close();
      const second = await director.open({ bundleId: "com.apple.TextEdit" });
      assert.equal(live.has(first.layer!.pid), false);
      assert.equal(live.has(second.layer!.pid), true);
      assert.equal(live.has(4000), true);
      assert.equal(first.layer?.displayId, second.layer?.displayId);
      assert.notEqual(first.layer?.startedAt, second.layer?.startedAt);
      assert.deepEqual((await director.status()).subject, { bundleId: "com.apple.TextEdit" });
    } finally {
      await cleanup();
    }
  });

  test("close stops the layer and clears its files", async () => {
    const { director, live, cleanup } = await fixture();
    try {
      const opened = await director.open({ bundleId: "com.apple.calculator" });
      const closed = await director.close();
      assert.equal(closed.active, false);
      assert.equal(live.has(opened.layer!.pid), false);
      assert.equal(await exists(director.paths().state), false);
      assert.equal(await exists(director.paths().request), false);
      assert.equal((await director.status()).active, false);
      assert.equal((await director.displayStatus()).active, true);
      assert.equal(live.has(4000), true);
    } finally {
      await cleanup();
    }
  });

  test("close falls back to SIGTERM when the stop file is ignored", async () => {
    const { director, terminated, cleanup } = await fixture({ stopExits: false });
    try {
      const opened = await director.open({ bundleId: "com.apple.calculator" });
      const closed = await director.close();
      assert.deepEqual(terminated, [opened.layer!.pid]);
      assert.equal(closed.active, false);
    } finally {
      await cleanup();
    }
  });

  test("status reports a dead layer without racing lifecycle file mutations", async () => {
    const { director, live, cleanup } = await fixture();
    try {
      const opened = await director.open({ bundleId: "com.apple.calculator" });
      live.delete(opened.layer!.pid);
      const status = await director.status();
      assert.equal(status.active, false);
      assert.equal(status.layer, undefined);
      assert.equal(await exists(director.paths().state), true);
      assert.equal(await director.routing(), undefined);
    } finally {
      await cleanup();
    }
  });

  test("routing falls back to the first moved window when no subject was given", async () => {
    const { director, cleanup } = await fixture();
    try {
      await director.open({});
      assert.deepEqual((await director.routing())?.bundleId, "com.apple.calculator");
      const request = JSON.parse(await readFile(director.paths().request, "utf8")) as { subject?: unknown };
      assert.equal(request.subject, undefined);
    } finally {
      await cleanup();
    }
  });

  test("open fails and tears down when no state file lands", async () => {
    const { director, live, cleanup } = await fixture({ writeState: false });
    try {
      await assert.rejects(director.open({ bundleId: "com.apple.calculator" }), /never wrote its state file/);
      assert.deepEqual([...live], [4000]);
    } finally {
      await cleanup();
    }
  });

  test("pause refuses actions and operator resume permits them", async () => {
    const { director, cleanup } = await fixture();
    try {
      const opened = await director.open();
      await writeFile(director.paths().state, JSON.stringify({ ...opened.layer, paused: true }));
      assert.match(await director.actRefusal() ?? "", /operator paused/);
      await writeFile(director.paths().state, JSON.stringify({ ...opened.layer, paused: false }));
      assert.equal(await director.actRefusal(), undefined);
    } finally {
      await cleanup();
    }
  });

  for (const action of ["stop", "takeover"]) {
    test(`${action} refuses actions during teardown and survives cleanup`, async () => {
      const { director, cleanup } = await fixture();
      try {
        const opened = await director.open();
        const { pid, displayId, startedAt } = opened.layer!;
        await writeFile(director.paths().handoff, JSON.stringify({ action, pid, displayId, startedAt }));
        const refusal = await director.actRefusal();
        assert.match(refusal ?? "", action === "stop" ? /operator stopped/ : /operator took over/);
        assert.match(refusal ?? "", /fresh user authorization/);
        assert.doesNotMatch(refusal ?? "", /windows are back/);
        await director.close();
        assert.equal(await director.actRefusal(), refusal);
        assert.equal((await director.displayStatus()).active, true);
        await director.open();
        assert.equal(await director.actRefusal(), undefined);
      } finally {
        await cleanup();
      }
    });
  }

  test("an old handoff cannot stop a different live session", async () => {
    const { director, cleanup } = await fixture();
    try {
      const opened = await director.open();
      await writeFile(director.paths().handoff, JSON.stringify({
        action: "stop", pid: opened.layer!.pid, displayId: opened.layer!.displayId, startedAt: "previous-session",
      }));
      assert.equal(await director.actRefusal(), undefined);
    } finally {
      await cleanup();
    }
  });
});
