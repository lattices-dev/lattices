import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { appendFile, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { describe, test, type TestContext } from "node:test";
import { askForBackend, availabilityCheck, permissionAsk, type AskLauncher } from "./ask.js";
import { BackendHost } from "./host.js";
import type { Backend, BackendAvailability, BackendCall } from "./types.js";

const launcherContext = { kind: "launcher" as const,
  description: "macOS grants access to the app launching agent-desktop. Enable the identity shown by macOS; Action does not know its exact name." };
const pending: BackendAvailability = { ready: false, permissionContext: launcherContext, needs: [{
  kind: "permission", permission: "screen-recording", app: process.execPath,
  detail: "Screen Recording is needed for window screenshots.", fix: "action setup agent-desktop",
}] };

function fixture(t: TestContext, overrides: Partial<Backend> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "action-ask-setup-"));
  const calls: BackendCall[] = [];
  const backend: Backend = {
    schema: 1,
    capabilities: { surfaces: ["computer"], observe: { ax: true, screenshot: true }, actions: {} },
    availability: async (call) => { calls.push(call); return { ready: true }; },
    targets: async () => [],
    observe: async () => { throw new Error("Unexpected observation"); },
    act: async () => { throw new Error("Unexpected action"); },
    dispose: async () => {},
    ...overrides,
  };
  const host = new BackendHost({ configPath: join(dir, "missing.json"), shotsDir: join(dir, "shots"), log: () => {},
    backends: { "agent-desktop": { summary: "fixture", factory: () => backend } } });
  t.after(async () => { await host.dispose(); rmSync(dir, { force: true, recursive: true }); });
  return { dir, host, calls };
}

type Panel = {
  request(): Promise<any>;
  control(): Promise<any>;
  click(step: string): Promise<void>;
  reply(outcome: string): Promise<void>;
};
function fakePanel(work: (panel: Panel) => Promise<void>) {
  let shown = 0;
  let finished: Promise<void> = Promise.resolve();
  const launcher: AskLauncher = async (args) => {
    shown++;
    const files: Record<string, string> = {};
    for (let index = 0; index < args.length; index += 2) files[args[index]!] = args[index + 1]!;
    finished = work({
      request: async () => JSON.parse(await readFile(files["--request"]!, "utf8")),
      control: async () => JSON.parse(await readFile(files["--control-file"]!, "utf8")),
      click: async (step) => { await appendFile(files["--events-file"]!, `${JSON.stringify({ step })}\n`); },
      reply: async (outcome) => { await writeFile(files["--reply-file"]!, JSON.stringify({ status: "answered", outcome })); },
    });
    void finished.catch(() => {}); // The test awaits the same task after the ask finishes.
  };
  return { launcher, shown: () => shown, finished: () => finished };
}
async function until(check: () => boolean | Promise<boolean>) {
  const deadline = Date.now() + 1_000;
  while (!(await check())) {
    if (Date.now() >= deadline) throw new Error("Fake ask panel did not progress.");
    await delay(2);
  }
}
const fast = { supported: async () => true, checkMs: 10, pollMs: 2, timeoutMs: 1_000 };

describe("backend setup asks", () => {
  test("failed readiness probes never infer that missing permissions were granted", async () => {
    const items = ["accessibility", "screen-recording"];
    const config = { kind: "config" as const, detail: "Invalid status", fix: "Check the executable." };
    const failures: BackendAvailability[] = [
      { ready: false, reason: "Status could not be verified." },
      { ready: false, needs: [] },
      { ready: false, needs: [config] },
      { ready: false, needs: [...pending.needs!, config] },
      { ready: false, needs: [{ kind: "permission", detail: "Unknown permission", fix: "Check status." }] },
    ];
    for (const failure of failures) {
      const check = await availabilityCheck(async () => failure, items)();
      assert.equal(check.satisfied, false);
      assert.deepEqual(check.items, { accessibility: "unknown", "screen-recording": "unknown" });
    }
    const thrown = await availabilityCheck(async () => { throw new Error("Probe failed."); }, items)();
    assert.equal(thrown.satisfied, false);
    assert.equal(thrown.detail, "Probe failed.");
    assert.deepEqual(thrown.items, { accessibility: "unknown", "screen-recording": "unknown" });
    assert.deepEqual(await availabilityCheck(async () => pending, items)(), {
      satisfied: false, items: { accessibility: "granted", "screen-recording": "missing" },
    });
    assert.deepEqual(await availabilityCheck(async () => ({ ready: true }), items)(), {
      satisfied: true, items: { accessibility: "granted", "screen-recording": "granted" },
    });
  });

  test("a later failed status probe clears previously granted panel items", async (t) => {
    let status: BackendAvailability = { ...pending, needs: [
      { kind: "permission", permission: "accessibility", detail: "Accessibility is missing.", fix: "Grant access." },
      ...pending.needs!,
    ] };
    const f = fixture(t, { setupAvailability: async () => status });
    const panel = fakePanel(async (p) => {
      status = pending;
      await until(async () => (await p.control()).items.find((item: any) => item.id === "accessibility")?.state === "granted");
      status = { ready: false, reason: "Permission status could not be verified.",
        needs: [{ kind: "config", detail: "Invalid permission evidence.", fix: "Check the executable." }] };
      await until(async () => (await p.control()).items.every((item: any) => item.state === "unknown"));
      const control = await p.control();
      assert.equal(control.status, "waiting");
      assert.equal(control.detail, status.reason);
      await p.reply("declined");
    });
    const result = await askForBackend(f.host, "agent-desktop", { ...fast, dir: f.dir, launcher: panel.launcher });
    await panel.finished();
    assert.equal(result.outcome, "declined");
    assert.deepEqual(result.needs, status.needs);
  });

  test("setupAvailability falls back to normal availability and preserves the call", async (t) => {
    const f = fixture(t);
    assert.deepEqual(await f.host.setupAvailability("agent-desktop", { caller: "fixture", sessionId: "session", timeoutMs: 321 }), { ready: true });
    assert.equal(f.calls.length, 1);
    assert.equal(f.calls[0]!.caller, "fixture");
    assert.equal(f.calls[0]!.sessionId, "session");
    assert.ok(f.calls[0]!.deadline <= Date.now() + 321);
    const panel = fakePanel(async () => { throw new Error("Already ready must not show a panel"); });
    assert.deepEqual(await askForBackend(f.host, "agent-desktop", { ...fast, dir: f.dir, launcher: panel.launcher }), { outcome: "satisfied", asked: false });
    assert.equal(panel.shown(), 0);
  });

  test("explicit setup can require screenshots while ordinary AX operations are ready", async (t) => {
    let granted = false;
    let setupReads = 0;
    const f = fixture(t, { setupAvailability: async () => { setupReads++; return granted ? { ready: true } : pending; } });
    assert.equal((await f.host.availability("agent-desktop")).ready, true);
    const panel = fakePanel(async (p) => {
      const request = await p.request();
      assert.deepEqual(request.items.map((item: any) => item.id), ["screen-recording"]);
      assert.equal(request.why, launcherContext.description);
      assert.equal(request.subject, undefined);
      assert.ok(!request.steps.some((step: any) => step.id === "reveal"));
      granted = true;
      await until(async () => (await p.control()).status === "satisfied");
      await p.reply("satisfied");
    });
    const result = await askForBackend(f.host, "agent-desktop", { ...fast, dir: f.dir, launcher: panel.launcher });
    await panel.finished();
    assert.equal(result.outcome, "satisfied");
    assert.equal(result.asked, true);
    assert.equal(f.calls.length, 1, "ask polling uses setup requirements, not AX-only availability");
    assert.ok(setupReads >= 3);
  });

  test("launcher wording never fabricates a subject even if an executable path is supplied", () => {
    const request = permissionAsk("agent-desktop", pending.needs!, {
      appPath: "/Applications/Action.app", permissionContext: launcherContext, retry: true,
    })!;
    assert.equal(request.title, "Set up agent-desktop permissions");
    assert.equal(request.why, launcherContext.description);
    assert.equal(request.subject, undefined);
    assert.deepEqual(request.steps!.map((step) => step.id), ["open-screen-recording", "retry"]);
    assert.equal(request.steps![1]!.label, "Request permissions");
    assert.equal(request.steps![1]!.action.kind, "agent");
    assert.ok(!JSON.stringify(request).includes("/Applications/Action.app"));
  });

  test("a scoped-request installation need returns unsupported without a panel", async (t) => {
    const need: BackendAvailability = { ready: false, reason: "Install a scoped-permission agent-desktop build.",
      needs: [{ kind: "install", detail: "Scoped requests are unavailable.", fix: "Install the supported CLI." }] };
    const f = fixture(t, { setupAvailability: async () => need });
    const panel = fakePanel(async () => { throw new Error("No permission panel for an installation need"); });
    const result = await askForBackend(f.host, "agent-desktop", { ...fast, dir: f.dir, launcher: panel.launcher });
    assert.equal(result.outcome, "unsupported");
    assert.deepEqual(result.needs, need.needs);
    assert.equal(result.detail, need.reason);
    assert.equal(panel.shown(), 0);
  });

  for (const outcome of ["declined", "expired"] as const) {
    test(`${outcome} aborts and settles retry setup while status polling remains live`, async (t) => {
      let reads = 0, starts = 0;
      let aborted = false, settled = false;
      const f = fixture(t, {
        setupAvailability: async () => { reads++; return pending; },
        setup: async (call, opts) => {
          starts++;
          assert.equal(opts.interactive, true);
          assert.equal(call.caller, "original-caller");
          assert.equal(call.sessionId, "original-session");
          await new Promise<void>((resolve) => {
            const finish = () => { aborted = true; resolve(); };
            call.signal.addEventListener("abort", finish, { once: true });
            if (call.signal.aborted) finish();
          });
          await delay(15); // Settling cleanup must finish before askForBackend returns.
          settled = true;
          return { ready: false, steps: [] };
        },
      });
      const panel = fakePanel(async (p) => {
        await p.click("retry");
        await until(() => starts === 1);
        const before = reads;
        await p.click("retry"); // An active request must not be duplicated.
        await until(() => reads > before);
        if (outcome === "expired") await until(async () => (await p.control()).status === "cancelled");
        await p.reply(outcome);
      });
      const result = await askForBackend(f.host, "agent-desktop", { ...fast, timeoutMs: outcome === "expired" ? 100 : 1_000,
        dir: f.dir, launcher: panel.launcher, call: { caller: "original-caller", sessionId: "original-session" } });
      await panel.finished();
      assert.equal(result.outcome, outcome);
      assert.equal(starts, 1);
      assert.equal(aborted, true);
      assert.equal(settled, true);
    });
  }

  for (const source of ["ask", "call"] as const) {
    test(`cancellation from the ${source} signal reaches panel and retry setup`, async (t) => {
      const cancellation = new AbortController();
      let started = false, settled = false;
      const f = fixture(t, {
        setupAvailability: async () => pending,
        setup: async (call) => {
          started = true;
          await new Promise<void>((resolve) => {
            call.signal.addEventListener("abort", () => resolve(), { once: true });
            if (call.signal.aborted) resolve();
          });
          settled = true;
          return { ready: false, steps: [] };
        },
      });
      const panel = fakePanel(async (p) => {
        await p.click("retry");
        await until(() => started);
        cancellation.abort();
        await until(async () => (await p.control()).status === "cancelled");
        await p.reply("cancelled");
      });
      const result = await askForBackend(f.host, "agent-desktop", { ...fast, dir: f.dir, launcher: panel.launcher,
        ...(source === "ask" ? { signal: cancellation.signal } : { call: { signal: cancellation.signal } }) });
      await panel.finished();
      assert.equal(result.outcome, "cancelled");
      assert.equal(settled, true);
    });
  }
});
