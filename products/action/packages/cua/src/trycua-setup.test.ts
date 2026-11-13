import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test, type TestContext } from "node:test";
import { createTrycuaCuaBackend } from "./trycua-cua.js";
import { BackendRefusal, type BackendCall, type BackendContext, type McpClient, type McpToolResult } from "./types.js";

const call = (signal = new AbortController().signal): BackendCall => ({
  requestId: "setup-test", caller: "test", signal, deadline: Date.now() + 120_000,
});
type CommandResult = { stdout: string; stderr?: string; exitCode: number | null; timedOut?: boolean };
type Sent = { command: string; args: string[]; timeoutMs: number; stream: boolean; remainingMs: number; onOutput?: (output: string) => void };
const result = (value: unknown): CommandResult => ({ stdout: JSON.stringify(value), exitCode: 0 });
const missing = { accessibility: false, screen_recording: false };
const granted = { accessibility: true, screen_recording: true, screen_recording_capturable: null, direct_capture_status: "not_checked" };

function fixture(t: TestContext, opts: {
  run?: (sent: Sent, call: BackendCall) => Promise<CommandResult>;
  poll?: (call: BackendCall, intervalMs?: number) => Promise<void>;
  health?: McpToolResult;
  command?: string;
  log?: (...args: unknown[]) => void;
  realSpawn?: boolean;
} = {}) {
  const dir = mkdtempSync(join(tmpdir(), "trycua-setup-"));
  const sent: Sent[] = [];
  const events: string[] = [];
  const logs: unknown[][] = [];
  const ctx: BackendContext = {
    generation: "setup-test", shotsDir: dir,
    options: {
      command: opts.command ?? process.execPath,
      ...(!opts.realSpawn ? { __setupRun: async (command: string, args: string[], request: BackendCall, settings: { timeoutMs: number; stream: boolean; onOutput?: (output: string) => void }) => {
        const item = { command, args, remainingMs: request.deadline - Date.now(), ...settings };
        sent.push(item);
        events.push(args.join(" "));
        return opts.run ? await opts.run(item, request) : result(args[1] === "grant"
          ? { ...granted, screen_recording_capturable: true, direct_capture_status: "ready" } : granted);
      } } : {}),
      __setupPoll: async (request: BackendCall, intervalMs?: number) => { events.push("poll"); await opts.poll?.(request, intervalMs); },
    },
    stdioMcp: async () => ({
      serverInfo: { name: "cua-driver", version: "test" }, listTools: async () => [],
      callTool: async () => opts.health ?? ({ structuredContent: { overall: "ok", checks: [] } }),
      close: () => { events.push("close-mcp"); },
    }),
    newestDir: () => null,
    log: (...args) => { logs.push(args); opts.log?.(...args); },
    refuse: (code, message, observation) => new BackendRefusal(code, message, observation),
  };
  const backend = createTrycuaCuaBackend(ctx);
  t.after(async () => { await backend.dispose(); rmSync(dir, { recursive: true, force: true }); });
  return { backend, ctx, sent, events, logs, dir };
}

describe("trycua setup", () => {
  test("permissions_pending and unknown health map both grants to CuaDriver", async (t) => {
    for (const health of [
      { isError: true, content: [{ type: "text", text: "permissions_pending: waiting for macOS" }] },
      { isError: true, structuredContent: { status: "refused", refusal: { code: "permissions_pending", message: "waiting" } } },
      { structuredContent: { overall: "unknown" } },
      { structuredContent: { status: "unknown" } },
      { structuredContent: {} },
      { structuredContent: { overall: 42 } },
      { structuredContent: [] },
      { structuredContent: { overall: "ok", checks: { bad: true } } },
      { structuredContent: { overall: "ok", checks: [null] } },
      { isError: true, content: [{ type: "text", text: "permission status unknown" }] },
    ] satisfies McpToolResult[]) {
      const { backend } = fixture(t, { health });
      const availability = await backend.availability(call());
      assert.equal(availability.ready, false);
      assert.deepEqual(availability.needs?.map((need) => [need.kind, need.permission, need.app, need.fix]), [
        ["permission", "accessibility", "com.trycua.driver", "action setup trycua-cua"],
        ["permission", "screen-recording", "com.trycua.driver", "action setup trycua-cua"],
      ]);
    }
  });

  test("health names just the missing grant and never considers absent screen recording ready", async (t) => {
    const { backend } = fixture(t, { health: { structuredContent: { overall: "degraded", checks: [
      { name: "tcc_accessibility", status: "pass" }, { name: "tcc_screen_recording", status: "fail" },
    ] } } });
    const availability = await backend.availability(call());
    assert.equal(availability.ready, false);
    assert.deepEqual(availability.needs?.map((need) => need.permission), ["screen-recording"]);
  });

  test("running unknown driver restarts and opens guidance before the background grant resolves", async (t) => {
    let grantResolved = false;
    let grantStarted = false;
    let finishGrant!: (value: CommandResult) => void;
    const grant = new Promise<CommandResult>((resolve) => { finishGrant = resolve; });
    const unknown = { daemon_running: true, status: "unknown" };
    const f = fixture(t, { run: async ({ args }) => {
      if (args[1] === "status") return result(unknown);
      if (args[1] === "grant") { grantStarted = true; return await grant; }
      if (args[0] === "-R") {
        assert.equal(grantStarted, true);
        assert.equal(grantResolved, false);
        assert.ok(f.events.includes("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"));
        assert.ok(f.events.includes("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"));
        grantResolved = true;
        finishGrant({ stdout: "Permissions and capture verified", exitCode: 0 });
      }
      return result({});
    } });
    const setup = await f.backend.setup!({ ...call(), deadline: Date.now() + 250 }, { interactive: true });
    assert.equal(setup.ready, true);
    assert.equal(grantResolved, true);
    assert.deepEqual(f.events.slice(0, 3), ["permissions status --json", "stop", "permissions grant"]);
    assert.ok(setup.steps.some((step) => step.step === "restart-driver" && step.status === "done"));
    for (const permission of ["accessibility", "screen-recording"]) {
      assert.ok(setup.steps.some((step) => step.step === `open-${permission}-settings`
        && step.status === "waiting-on-user" && /CuaDriver/.test(step.detail ?? "")));
    }
    assert.ok(setup.steps.some((step) => /click \+|drag/.test(step.detail ?? "")));
  });

  test("deadline kills the pending grant after both Settings panes and Finder are open", async (t) => {
    let killed = false;
    let polls = 0;
    const f = fixture(t, {
      run: async ({ args, onOutput }, request) => {
        if (args[1] === "status") return result({ daemon_running: true, status: "unknown" });
        if (args[1] === "grant") {
          onOutput?.("Launching CuaDriver to request permissions. A dialog for CuaDriver will appear…");
          return await new Promise<CommandResult>((resolve) => {
            request.signal.addEventListener("abort", () => {
              killed = true;
              resolve({ stdout: "waiting for approval", exitCode: null });
            }, { once: true });
          });
        }
        return result({});
      },
      poll: async (request) => {
        // Skip the launch grace period, then wait as a real poll would.
        if (++polls === 1) return;
        await new Promise<void>((resolve) => request.signal.addEventListener("abort", () => resolve(), { once: true }));
      },
    });
    const setup = await f.backend.setup!({ ...call(), deadline: Date.now() + 100 }, { interactive: true });
    assert.equal(setup.ready, false);
    assert.equal(killed, true, "the pending command is cancelled at the overall deadline");
    assert.equal(setup.steps.at(-1)?.status, "waiting-on-user");
    assert.ok(f.events.includes("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"));
    assert.ok(f.events.includes("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"));
    assert.ok(f.events.includes("-R /Applications/CuaDriver.app"));
    assert.ok(f.sent.every((sent) => sent.timeoutMs > 0 && sent.timeoutMs <= sent.remainingMs + 1));
    assert.deepEqual(setup.needs?.map((need) => need.permission), ["accessibility", "screen-recording"]);
    assert.ok(setup.needs?.every((need) => /System Settings|Screen Recording/.test(need.detail)));
  });

  test("status polling cancels a pending request before one short capture verification", async (t) => {
    let statuses = 0;
    let grants = 0;
    let killed = false;
    const f = fixture(t, { run: async ({ args }, request) => {
      if (args[1] === "status") return result(++statuses === 1
        ? { daemon_running: true, status: "unknown" } : granted);
      if (args[1] === "grant") {
        if (++grants === 1) return await new Promise<CommandResult>((resolve) => {
          request.signal.addEventListener("abort", () => {
            killed = true;
            resolve({ stdout: "cancelled initial grant", exitCode: null });
          }, { once: true });
        });
        assert.equal(killed, true, "verification cannot overlap the initial grant");
        return result({ ...granted, screen_recording_capturable: true, direct_capture_status: "ready" });
      }
      return result({});
    } });
    const setup = await f.backend.setup!({ ...call(), deadline: Date.now() + 500 }, { interactive: true });
    assert.equal(setup.ready, true);
    assert.equal(grants, 2);
    assert.equal(killed, true);
    assert.ok(statuses >= 2);
    assert.ok(f.events.includes("poll"));
    const verify = f.sent.filter((sent) => sent.args[1] === "grant")[1]!;
    assert.ok(verify.timeoutMs <= 10_000 && verify.timeoutMs <= verify.remainingMs + 1);
    assert.ok(setup.steps.some((step) => step.step === "verify-capture" && step.status === "done"));
  });

  test("a verified grant completes while a parallel status read is still pending", async (t) => {
    let statuses = 0;
    let pollCancelled = false;
    let finishGrant!: (value: CommandResult) => void;
    const grant = new Promise<CommandResult>((resolve) => { finishGrant = resolve; });
    const f = fixture(t, { run: async ({ args }, request) => {
      if (args[1] === "grant") return await grant;
      if (args[1] === "status") {
        if (++statuses === 1) return result({ daemon_running: true, status: "unknown" });
        finishGrant({ stdout: "Permission and capture verification completed", exitCode: 0 });
        return await new Promise<CommandResult>((resolve) => {
          request.signal.addEventListener("abort", () => {
            pollCancelled = true;
            resolve(result({ status: "unknown" }));
          }, { once: true });
        });
      }
      return result({});
    } });
    const setup = await f.backend.setup!({ ...call(), deadline: Date.now() + 250 }, { interactive: true });
    assert.equal(setup.ready, true);
    assert.equal(statuses, 2);
    assert.equal(pollCancelled, true, "successful setup cleans up the concurrent status command");
    assert.equal(f.sent.filter((sent) => sent.args[1] === "grant").length, 1);
    assert.equal(setup.steps.at(-1)?.step, "ready");
  });

  test("a running driver with just one missing grant restarts and opens only that pane", async (t) => {
    let finishGrant!: (value: CommandResult) => void;
    const grant = new Promise<CommandResult>((resolve) => { finishGrant = resolve; });
    const f = fixture(t, { run: async ({ args }) => {
      if (args[1] === "status") return result({ daemon_running: true, accessibility: true, screen_recording: false });
      if (args[1] === "grant") return await grant;
      if (args[0] === "-R") finishGrant({ stdout: "Capture verified", exitCode: 0 });
      return result({});
    } });
    const setup = await f.backend.setup!({ ...call(), deadline: Date.now() + 250 }, { interactive: true });
    assert.equal(setup.ready, true);
    assert.deepEqual(f.events.slice(0, 3), ["permissions status --json", "stop", "permissions grant"]);
    assert.ok(f.events.includes("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"));
    assert.ok(!f.events.includes("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"));
  });

  test("grant timeout leads to exact panes, Finder, polling, and a fresh capture verification", async (t) => {
    let statuses = 0;
    let grants = 0;
    const f = fixture(t, { run: async ({ args }) => {
      if (args[0] === "permissions" && args[1] === "grant") return ++grants === 1
        ? { stdout: "still waiting", exitCode: null, timedOut: true }
        : result({ ...granted, screen_recording_capturable: true, direct_capture_status: "ready" });
      if (args[1] === "status") return result(++statuses < 3 ? missing : granted);
      return result({});
    } });
    await f.backend.availability(call()); // Establish a connection whose daemon may restart during setup.
    const liveSteps: string[] = [];
    const setup = await f.backend.setup!({ ...call(), onSetupStep: (step) => liveSteps.push(`${step.step}:${step.status}`) }, { interactive: true });
    assert.equal(setup.ready, true);
    assert.equal(setup.needs, undefined);
    assert.equal(f.events[0], "permissions status --json");
    assert.ok(f.events.indexOf("permissions grant") < f.events.indexOf("-R /Applications/CuaDriver.app"));
    assert.ok(f.events.includes("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"));
    assert.ok(f.events.includes("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"));
    assert.ok(f.events.includes("poll"));
    assert.equal(f.events.at(-1), "close-mcp");
    const grantCommands = f.sent.filter((item) => item.args[1] === "grant");
    assert.equal(grantCommands.length, 2);
    assert.ok(grantCommands.every((item) => item.stream && item.timeoutMs > 0 && item.timeoutMs <= item.remainingMs + 1));
    assert.ok(grantCommands[1]!.timeoutMs <= 10_000);
    assert.ok(setup.steps.some((step) => step.status === "waiting-on-user" && /drag|click \+/.test(step.detail ?? "")));
    assert.equal(liveSteps.at(-1), "ready:done");
  });

  test("already granted permissions and successful capture verification need no Settings", async (t) => {
    const f = fixture(t);
    const setup = await f.backend.setup!(call(), { interactive: true });
    assert.equal(setup.ready, true);
    assert.deepEqual(f.events, ["permissions status --json", "permissions grant"]);
  });

  test("noninteractive setup reports needs without prompting, opening Settings or polling", async (t) => {
    for (const status of [missing, { daemon_running: true, status: "unknown" }]) {
      const f = fixture(t, { run: async () => result(status) });
      const setup = await f.backend.setup!(call(), { interactive: false });
      assert.equal(setup.ready, false);
      assert.equal(setup.needs?.length, 2);
      assert.deepEqual(f.events, ["permissions status --json"]);
      assert.ok(setup.steps.some((step) => step.status === "skipped"));
    }
  });

  test("unknown status is never treated as a permission grant", async (t) => {
    const f = fixture(t, { run: async () => result({ status: "unknown" }) });
    const setup = await f.backend.setup!(call(), { interactive: false });
    assert.equal(setup.ready, false);
    assert.equal(setup.needs?.length, 2);
  });

  test("timeout or cancellation returns waiting-on-user with the exact fix", async (t) => {
    const controller = new AbortController();
    const f = fixture(t, {
      run: async ({ args }) => args[1] === "grant" ? { stdout: "still waiting", exitCode: 1 } : result(missing),
      poll: async () => { controller.abort(); throw new Error("cancelled"); },
    });
    const setup = await f.backend.setup!(call(controller.signal), { interactive: true });
    assert.equal(setup.ready, false);
    assert.equal(setup.steps.at(-1)?.status, "waiting-on-user");
    assert.ok(setup.needs?.every((need) => need.fix === "action setup trycua-cua"));
    assert.equal(f.events.filter((event) => event === "permissions grant").length, 1);
  });

  test("a grant that explicitly skipped capture verification never returns ready", async (t) => {
    const f = fixture(t, { run: async () => result(granted) });
    const setup = await f.backend.setup!(call(), { interactive: true });
    assert.equal(setup.ready, false);
    assert.equal(setup.needs?.[0]?.kind, "approval");
  });

  test("a pre-aborted setup never spawns a process", async (t) => {
    const controller = new AbortController();
    controller.abort();
    const f = fixture(t);
    const setup = await f.backend.setup!(call(controller.signal), { interactive: true });
    assert.equal(setup.ready, false);
    assert.deepEqual(f.sent, []);
  });

  test("capture failure after grants flip never returns ready", async (t) => {
    let grants = 0;
    const f = fixture(t, { run: async ({ args }) => args[1] === "grant"
      ? (++grants, { stdout: "capture probe failed", exitCode: 1 })
      : result(granted) });
    const setup = await f.backend.setup!(call(), { interactive: true });
    assert.equal(setup.ready, false);
    assert.equal(grants, 2);
    assert.equal(setup.needs?.[0]?.kind, "approval");
    assert.match(setup.needs?.[0]?.detail ?? "", /capture/);
  });

  test("missing driver reports install instructions without any process", async (t) => {
    const f = fixture(t, { command: "/nonexistent/action-test/cua-driver" });
    const setup = await f.backend.setup!(call(), { interactive: true });
    assert.equal(setup.ready, false);
    assert.equal(setup.needs?.[0]?.kind, "install");
    assert.match(setup.needs?.[0]?.detail ?? "", /https:\/\/cua.ai\/docs\/cua-driver\/quickstart/);
    assert.deepEqual(f.sent, []);
  });

  test("aborting during grant or status cannot turn a late transport reply into ready", async (t) => {
    for (const abortDuring of ["grant", "status"]) {
      const controller = new AbortController();
      const f = fixture(t, { run: async ({ args }) => {
        if (args[1] === abortDuring) controller.abort();
        return result({ ...granted, screen_recording_capturable: true, direct_capture_status: "ready" });
      } });
      const setup = await f.backend.setup!(call(controller.signal), { interactive: true });
      assert.equal(setup.ready, false);
      assert.notEqual(setup.steps.at(-1)?.step, "ready");
    }
  });

  test("a failing status recheck discards an earlier granted status", async (t) => {
    let statusReads = 0;
    const f = fixture(t, { run: async ({ args }) => {
      if (args[1] === "grant") return result(granted); // Explicitly unverified; triggers another grant.
      if (++statusReads === 1) return result(granted);
      throw new Error("status connection closed");
    } });
    const setup = await f.backend.setup!(call(), { interactive: true });
    assert.equal(setup.ready, false);
    assert.deepEqual(setup.needs?.map((need) => need.permission), ["accessibility", "screen-recording"]);
  });

  test("a transport ignoring the signal is bounded by the setup deadline", async (t) => {
    const f = fixture(t, { run: async () => await new Promise<CommandResult>(() => {}) });
    const setup = await f.backend.setup!({ ...call(), deadline: Date.now() + 20 }, { interactive: true });
    assert.equal(setup.ready, false);
    assert.equal(setup.steps.at(-1)?.status, "waiting-on-user");
    assert.deepEqual(f.events, ["permissions status --json"]);
  });

  test("setup and dispose do not await an earlier pending MCP handshake", async (t) => {
    const f = fixture(t);
    let connect!: (client: McpClient) => void;
    let closed = 0;
    const backend = createTrycuaCuaBackend({ ...f.ctx,
      stdioMcp: async () => await new Promise<McpClient>((resolve) => { connect = resolve; }),
    });
    const availability = backend.availability(call());
    const setup = await backend.setup!({ ...call(), deadline: Date.now() + 50 }, { interactive: true });
    assert.equal(setup.ready, true);
    await backend.dispose();
    connect({
      serverInfo: null, listTools: async () => [], close: () => { closed += 1; },
      callTool: async () => ({ structuredContent: { overall: "ok", checks: [] } }),
    });
    await availability;
    assert.equal(closed, 1, "the late connection is still cleaned up");
  });

  test("the spawned grant streams logs and respects cancellation (fake executable only)", async (t) => {
    const controller = new AbortController();
    const dir = mkdtempSync(join(tmpdir(), "trycua-fake-driver-"));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const command = join(dir, "fake-driver");
    writeFileSync(command, '#!/bin/sh\nif [ "$2" = "status" ]; then\n  printf \'{"accessibility":true,"screen_recording":true}\\n\'\n  exit 0\nfi\nprintf "FAKE_GRANT_STARTED\\n"\nexec /bin/sleep 30\n', { mode: 0o755 });
    const f = fixture(t, { command, realSpawn: true, log: (...parts) => {
      if (parts.join(" ").includes("FAKE_GRANT_STARTED")) controller.abort();
    } });
    const setup = await f.backend.setup!(call(controller.signal), { interactive: true });
    assert.equal(setup.ready, false);
    assert.ok(f.logs.some((parts) => parts.join(" ").includes("FAKE_GRANT_STARTED")));
    assert.equal(setup.steps.at(-1)?.status, "waiting-on-user");
  });
});
