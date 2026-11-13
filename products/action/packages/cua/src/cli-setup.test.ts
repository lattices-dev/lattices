import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test, type TestContext } from "node:test";
import { runCli } from "./cli.js";
import { BackendHost } from "./host.js";
import { cuaHandlers } from "./tools.js";
import type { BackendFactory, BackendNeed, BackendSetupResult, BackendSetupStep } from "./types.js";

function fixture(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), "action-cua-setup-cli-"));
  const events: string[] = [];
  const stdout: string[] = [];
  const stderr: string[] = [];
  const state = {
    ready: false,
    setupReady: true,
    needKind: "permission" as BackendNeed["kind"],
    throwFirst: false,
    onStep: undefined as (() => void) | undefined,
  };
  const needs = (id: string): BackendNeed[] => [{
    kind: state.needKind, permission: state.needKind === "permission" ? "accessibility" : undefined,
    app: "com.example.driver", detail: "Enable Example Driver under Privacy & Security → Accessibility.",
    fix: `action setup ${id}`,
  }];
  const factory = (id: string): BackendFactory => (ctx) => ({
    schema: 1,
    capabilities: { surfaces: ["computer"], observe: { ax: true, screenshot: false }, actions: { press: "semantic", setValue: "semantic", key: "attention" } },
    async availability() {
      events.push(`${id}:status`);
      return state.ready ? { ready: true } : { ready: false, reason: "permissions_pending", needs: needs(id) };
    },
    async setup(call, opts) {
      events.push(`${id}:setup:${opts.interactive}`);
      assert.ok(call.deadline - Date.now() > 100_000, "setup has a roughly two-minute budget");
      if (state.throwFirst && id === "fake-cua") throw new Error("fake setup failure");
      const steps: BackendSetupStep[] = [{
        step: "Enable Accessibility", status: "waiting-on-user", detail: needs(id)[0]!.detail,
      }];
      call.onSetupStep?.(steps[0]!);
      state.onStep?.();
      if (state.setupReady) {
        state.ready = true;
        steps.push({ step: "Verify permissions", status: "done" });
        call.onSetupStep?.(steps[1]!);
      }
      return { ready: state.setupReady, steps, ...(state.setupReady ? {} : { needs: needs(id) }) };
    },
    async targets() {
      events.push(`${id}:targets`);
      return [{ targetId: `${ctx.generation}:window`, app: "Example", bundleId: "com.example.target" }];
    },
    async observe(_call, targetId) {
      events.push(`${id}:observe`);
      return { observationId: "fresh-1", targetId, at: 1, ax: [{ ref: "fresh-1.1", depth: 0, role: "AXButton", label: "Save" }] };
    },
    async act() {
      events.push(`${id}:act`);
      return { outcome: "dispatched", tierUsed: "semantic", mechanism: "fake:AXPress" };
    },
    async dispose() { events.push(`${id}:dispose`); },
  });
  const host = new BackendHost({
    backends: Object.fromEntries(["fake-cua", "other-cua"].map((id) => [id, { summary: id, factory: factory(id) }])),
    configPath: join(dir, "missing.json"), shotsDir: join(dir, "shots"), log: () => {},
  });
  t.after(async () => {
    await host.dispose();
    rmSync(dir, { force: true, recursive: true });
  });
  const options = { host, stdout: (text: string) => stdout.push(text), stderr: (text: string) => stderr.push(text) };
  return { host, state, events, stdout, stderr, options };
}

describe("CLI proactive setup", () => {
  const commands = [
    ["targets", "fake-cua"],
    ["observe", "fake-cua", "Example"],
    ["press", "fake-cua", "Example", "--label", "Save"],
    ["set", "fake-cua", "Example", "--label", "Save", "--value", "new"],
    ["act", "fake-cua", "Example", '{"kind":"key","combo":"cmd+l"}', "--allow", "attention"],
  ];

  for (const command of commands) {
    test(`${command[0]} prints a fix and exits nonzero without setup in a non-TTY`, async (t) => {
      const f = fixture(t);
      let prompted = false;
      const code = await runCli(command, { ...f.options, isTTY: false, prompt: async () => { prompted = true; return "y"; } });
      assert.equal(code, 1);
      assert.equal(prompted, false);
      assert.match(f.stderr.join(""), /Fix: action setup fake-cua/);
      assert.match(f.stderr.join(""), /com\.example\.driver/);
      assert.deepEqual(f.events, ["fake-cua:status", "fake-cua:dispose"]);
    });
  }

  test("non-TTY JSON includes structured needs and keeps diagnostics off stdout", async (t) => {
    const f = fixture(t);
    const code = await runCli(["targets", "fake-cua", "--json"], { ...f.options, isTTY: false });
    assert.equal(code, 1);
    const result = JSON.parse(f.stdout.join(""));
    assert.equal(result.code, "unavailable");
    assert.equal(result.needs[0].fix, "action setup fake-cua");
    assert.equal(result.delivery.status, "not_delivered");
    assert.equal(f.stderr.join(""), "");
  });

  for (const answer of ["", "y", "YES"]) {
    test(`TTY answer ${JSON.stringify(answer)} runs setup before observing and acting`, async (t) => {
      const f = fixture(t);
      const questions: string[] = [];
      const code = await runCli(["press", "fake-cua", "Example", "--label", "Save"], {
        ...f.options, isTTY: true, prompt: async (question) => { questions.push(question); return answer; },
      });
      assert.equal(code, 0);
      assert.deepEqual(questions, ["Run setup now? [Y/n] "]);
      assert.deepEqual(f.events, ["fake-cua:status", "fake-cua:setup:true", "fake-cua:targets", "fake-cua:observe", "fake-cua:act", "fake-cua:dispose"]);
    });
  }

  test("declining TTY setup preserves the fix and sends no action", async (t) => {
    const f = fixture(t);
    assert.equal(await runCli(["targets", "fake-cua"], { ...f.options, isTTY: true, prompt: async () => "n" }), 1);
    assert.match(f.stderr.join(""), /action setup fake-cua/);
    assert.deepEqual(f.events, ["fake-cua:status", "fake-cua:dispose"]);
  });

  test("TTY does not offer permission setup for an installation/configuration need", async (t) => {
    const f = fixture(t);
    f.state.needKind = "config";
    let prompted = false;
    assert.equal(await runCli(["targets", "fake-cua"], {
      ...f.options, isTTY: true, prompt: async () => { prompted = true; return "y"; },
    }), 1);
    assert.equal(prompted, false);
    assert.deepEqual(f.events, ["fake-cua:status", "fake-cua:dispose"]);
  });

  test("incomplete automatic setup never continues to targets or action", async (t) => {
    const f = fixture(t);
    f.state.setupReady = false;
    assert.equal(await runCli(["press", "fake-cua", "Example", "--label", "Save"], {
      ...f.options, isTTY: true, prompt: async () => "y",
    }), 1);
    assert.match(f.stderr.join(""), /waiting-on-user/);
    assert.deepEqual(f.events, ["fake-cua:status", "fake-cua:setup:true", "fake-cua:dispose"]);
  });
});

describe("CLI explicit setup and status", () => {
  test("explicit setup can run without a TTY, streams steps immediately, and keeps JSON clean", async (t) => {
    const f = fixture(t);
    f.state.onStep = () => {
      assert.match(f.stderr.join(""), /Enable Example Driver under Privacy & Security → Accessibility/);
      assert.equal(f.stdout.length, 0, "steps appear before the final result");
    };
    assert.equal(await runCli(["setup", "fake-cua", "--json"], { ...f.options, isTTY: false }), 0);
    const result = JSON.parse(f.stdout.join("")) as BackendSetupResult & { ok: boolean; backend: string };
    assert.equal(result.ok, true);
    assert.equal(result.ready, true);
    assert.equal(result.backend, "fake-cua");
    assert.equal(result.steps[1]?.status, "done");
    assert.deepEqual(f.events, ["fake-cua:setup:true", "fake-cua:dispose"]);
  });

  test("setup all continues after a backend fails and exits nonzero", async (t) => {
    const f = fixture(t);
    f.state.throwFirst = true;
    assert.equal(await runCli(["setup", "all", "--json"], f.options), 1);
    const result = JSON.parse(f.stdout.join("")) as { ok: boolean; backends: Array<BackendSetupResult & { backend: string }> };
    assert.equal(result.ok, false);
    assert.deepEqual(result.backends.map(({ backend, ready }) => ({ backend, ready })), [
      { backend: "fake-cua", ready: false }, { backend: "other-cua", ready: true },
    ]);
    assert.equal(result.backends[0]!.steps[0]!.status, "failed");
    assert.match(result.backends[0]!.steps[0]!.detail!, /fake setup failure/);
    assert.ok(f.events.includes("other-cua:setup:true"));
  });

  test("setup reports waiting-on-user and a fix when permission is still missing", async (t) => {
    const f = fixture(t);
    f.state.setupReady = false;
    assert.equal(await runCli(["setup", "fake-cua"], f.options), 1);
    assert.match(f.stderr.join(""), /fake-cua: not ready/);
    assert.match(f.stderr.join(""), /waiting-on-user/);
    assert.match(f.stderr.join(""), /Fix: action setup fake-cua/);
  });

  test("status prints permission app and setup command without running setup", async (t) => {
    const f = fixture(t);
    assert.equal(await runCli(["status", "fake-cua"], f.options), 0);
    assert.match(f.stdout.join(""), /Needs accessibility \(com\.example\.driver\)/);
    assert.match(f.stdout.join(""), /Fix: action setup fake-cua/);
    assert.deepEqual(f.events, ["fake-cua:status", "fake-cua:dispose"]);
  });

  test("MCP status includes needs and cua_setup reports steps and incomplete readiness", async (t) => {
    const f = fixture(t);
    f.state.setupReady = false;
    const handlers = cuaHandlers(f.host);
    const status = await handlers.cua_status!({ backend: "fake-cua" });
    const listed = status.structuredContent as { backends: Array<{ needs: BackendNeed[] }> };
    assert.equal(listed.backends[0]!.needs[0]!.fix, "action setup fake-cua");
    const setup = await handlers.cua_setup!({ backend: "fake-cua" });
    assert.equal(setup.isError, true);
    const result = setup.structuredContent as BackendSetupResult & { ok: boolean };
    assert.equal(result.ok, false);
    assert.equal(result.ready, false);
    assert.equal(result.steps[0]!.status, "waiting-on-user");
    assert.equal(result.needs![0]!.app, "com.example.driver");
    assert.ok(f.events.includes("fake-cua:setup:true"));
  });
});

describe("CLI setup cancellation", () => {
  for (const [signal, command] of [
    ["SIGINT", "setup"], ["SIGTERM", "setup"], ["SIGINT", "press"],
  ] as const) {
    test(`${signal} aborts a ${command} setup child, disposes the host, and stops further work`, async (t) => {
      const dir = mkdtempSync(join(tmpdir(), "action-cua-setup-cancel-"));
      const script = `
        import { spawn } from "node:child_process";
        import { BackendHost } from ${JSON.stringify(new URL("./host.ts", import.meta.url).href)};
        import { runCli } from ${JSON.stringify(new URL("./cli.ts", import.meta.url).href)};
        const before = [process.listenerCount("SIGINT"), process.listenerCount("SIGTERM")];
        const make = (id) => ({ summary: id, factory: () => ({
          schema: 1,
          capabilities: { surfaces: ["computer"], observe: { ax: true, screenshot: false }, actions: { press: "semantic" } },
          availability: async () => ({ ready: false, needs: [{ kind: "permission", permission: "accessibility", detail: "Fake permission", fix: "action setup " + id }] }),
          async setup(call) {
            if (id === "next-cua") throw new Error("NEXT_BACKEND_SETUP");
            const child = spawn(process.execPath, ["--eval", "process.stdout.write('READY'); setInterval(() => {}, 1000)"], { stdio: ["ignore", "pipe", "pipe"] });
            process.stderr.write("SETUP_CHILD_PID=" + child.pid + "\\n");
            child.stdout.once("data", () => process.stderr.write("SETUP_READY\\n"));
            const abort = () => { process.stderr.write("SETUP_ABORTED\\n"); child.kill("SIGKILL"); };
            call.signal.addEventListener("abort", abort, { once: true });
            if (call.signal.aborted) abort();
            await new Promise((resolve, reject) => { child.once("close", resolve); child.once("error", reject); });
            call.signal.removeEventListener("abort", abort);
            process.stderr.write("SETUP_CHILD_CLOSED\\n");
            return { ready: false, steps: [{ step: "Grant", status: "failed", detail: "Cancelled" }] };
          },
          targets: async () => { throw new Error("UNEXPECTED_TARGETS"); },
          observe: async () => { throw new Error("UNEXPECTED_OBSERVE"); },
          act: async () => { throw new Error("UNEXPECTED_ACTION"); },
          dispose: async () => { process.stderr.write("BACKEND_DISPOSED:" + id + "\\n"); }
        }) });
        const host = new BackendHost({
          configPath: ${JSON.stringify(join(dir, "missing.json"))}, shotsDir: ${JSON.stringify(join(dir, "shots"))},
          backends: { "fake-cua": make("fake-cua"), "next-cua": make("next-cua") }
        });
        const code = await runCli(${JSON.stringify(command === "setup" ? ["setup", "all", "--json"] : ["press", "fake-cua", "Example", "--label", "Save", "--json"])}, { host, isTTY: true, prompt: async () => "y" });
        if (before[0] === process.listenerCount("SIGINT") && before[1] === process.listenerCount("SIGTERM")) process.stderr.write("LISTENERS_RESTORED\\n");
        process.exitCode = code;
      `;
      const child = spawn(process.execPath, ["--eval", script], { stdio: ["ignore", "pipe", "pipe"] });
      let stdout = "";
      let stderr = "";
      let setupChildPid: number | undefined;
      let ready!: () => void;
      let failed!: (error: Error) => void;
      const started = new Promise<void>((resolve, reject) => { ready = resolve; failed = reject; });
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => { stdout += chunk; });
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk: string) => {
        stderr += chunk;
        const pid = /SETUP_CHILD_PID=(\d+)/.exec(stderr)?.[1];
        if (pid) setupChildPid = Number(pid);
        if (stderr.includes("SETUP_READY")) ready();
      });
      const exited = new Promise<{ code: number | null; signal: string | null }>((resolve, reject) => {
        child.once("error", (error) => { failed(error); reject(error); });
        child.once("close", (code, receivedSignal) => {
          failed(new Error(`CLI exited before its fake setup child started: ${stderr}`));
          resolve({ code, signal: receivedSignal });
        });
      });
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        failed(new Error(`CLI setup cancellation timed out: ${stderr}`));
      }, 5_000);
      t.after(async () => {
        clearTimeout(timer);
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        if (setupChildPid !== undefined) { try { process.kill(setupChildPid, "SIGKILL"); } catch {} }
        await exited.catch(() => {});
        rmSync(dir, { recursive: true, force: true });
      });
      await started;
      assert.ok(setupChildPid, "the fixture spawned only its inert fake grant process");
      child.kill(signal); // Signal only the CLI PID; the grant child relies on forwarding.
      assert.deepEqual(await exited, { code: signal === "SIGINT" ? 130 : 143, signal: null }, stderr);
      assert.match(stderr, /SETUP_ABORTED/);
      assert.match(stderr, /SETUP_CHILD_CLOSED/);
      assert.match(stderr, /BACKEND_DISPOSED:fake-cua/);
      assert.match(stderr, /LISTENERS_RESTORED/);
      assert.doesNotMatch(stderr + stdout, /NEXT_BACKEND_SETUP|UNEXPECTED_TARGETS|UNEXPECTED_OBSERVE|UNEXPECTED_ACTION/);
      assert.equal(JSON.parse(stdout).ok, false);
      assert.throws(() => process.kill(setupChildPid!, 0), (error: unknown) => (error as NodeJS.ErrnoException).code === "ESRCH");
    });
  }
});
