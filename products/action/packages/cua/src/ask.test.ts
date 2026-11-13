import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile, appendFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { askOperator, availabilityCheck, permissionAsk, validateAskRequest, type AskCheck, type AskRequest } from "./ask.js";

const request: AskRequest = {
  key: "tcc:com.example:accessibility",
  title: "Let Example control this Mac",
  why: "Example needs Accessibility.",
  items: [{ id: "accessibility", label: "Accessibility", state: "missing" }],
  steps: [
    { id: "open-ax", label: "Open Accessibility", action: { kind: "open-settings", pane: "accessibility" } },
    { id: "retry", label: "Ask macOS again", action: { kind: "agent" } },
  ],
};

type Panel = { args: Record<string, string>; reply(body: unknown): Promise<void>; click(step: string): Promise<void>; control(): Promise<any>; request(): Promise<any> };

/** A stand-in for Action's ask-user: hands the test the file paths it was launched with. */
function fakePanel(onLaunch: (panel: Panel) => void | Promise<void>) {
  let launches = 0;
  const launcher = async (argv: string[]) => {
    launches += 1;
    const args: Record<string, string> = {};
    for (let i = 0; i < argv.length; i += 2) args[argv[i]!.slice(2)] = argv[i + 1]!;
    const panel: Panel = {
      args,
      reply: (body) => writeFile(args["reply-file"]!, JSON.stringify(body)),
      click: (step) => appendFile(args["events-file"]!, `${JSON.stringify({ at: new Date().toISOString(), step })}\n`),
      control: async () => JSON.parse(await readFile(args["control-file"]!, "utf8")),
      request: async () => JSON.parse(await readFile(args.request!, "utf8")),
    };
    void onLaunch(panel);
  };
  return { launcher, launches: () => launches };
}

async function withDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = await mkdtemp(join(tmpdir(), "ask-test-"));
  try { return await fn(dir); } finally { await rm(dir, { recursive: true, force: true }); }
}

const fast = { checkMs: 20, pollMs: 10, supported: async () => true };

describe("askOperator", () => {
  test("shows nothing when the check is already satisfied", () => withDir(async (dir) => {
    const panel = fakePanel(() => {});
    const result = await askOperator(request, { ...fast, dir, launcher: panel.launcher, check: async () => ({ satisfied: true }) });
    expect(result).toEqual({ outcome: "satisfied", asked: false });
    expect(panel.launches()).toBe(0);
  }));

  test("ticks items from the check, closes on satisfied, and reports agent steps", () => withDir(async (dir) => {
    let granted = false;
    const steps: string[] = [];
    let seenWaiting: any;
    const panel = fakePanel(async (p) => {
      const sent = await p.request();
      expect(sent).toMatchObject({ schema: 1, key: request.key, title: request.title, resolution: "verify" });
      expect(typeof sent.expiresAt).toBe("string");
      await p.click("retry");
      for (;;) {
        const control = await p.control().catch(() => undefined);
        if (control?.detail === "half") seenWaiting = control;
        if (control?.status === "satisfied") {
          expect(control.items).toEqual([{ id: "accessibility", state: "granted" }]);
          await p.reply({ status: "answered", outcome: "satisfied" });
          return;
        }
        await new Promise((r) => setTimeout(r, 5));
      }
    });
    let calls = 0;
    const check = async (): Promise<AskCheck> => {
      calls += 1;
      if (calls === 1) return { satisfied: false };
      if (!granted) return { satisfied: false, items: { accessibility: "unknown" }, detail: "half" };
      return { satisfied: true };
    };
    const result = await askOperator(request, {
      ...fast, dir, launcher: panel.launcher, check,
      onStep: (step) => { steps.push(step); setTimeout(() => { granted = true; }, 60); },
    });
    expect(result.outcome).toBe("satisfied");
    expect(result.asked).toBe(true);
    expect(result.steps).toEqual(["retry"]);
    expect(steps).toEqual(["retry"]);
    expect(seenWaiting.items).toEqual([{ id: "accessibility", state: "unknown" }]);
    const log = (await readFile(join(dir, "log.jsonl"), "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    expect(log.map((entry) => entry.event ?? entry.outcome)).toEqual(["shown", "step", "satisfied"]);
  }));

  test("Not now is declined, unless the grant landed as it closed", () => withDir(async (dir) => {
    const declined = await askOperator(request, {
      ...fast, dir, check: async () => ({ satisfied: false }),
      launcher: fakePanel((p) => p.reply({ status: "answered", outcome: "declined" })).launcher,
    });
    expect(declined.outcome).toBe("declined");
    let n = 0;
    const raced = await askOperator(request, {
      ...fast, dir, check: async () => ({ satisfied: ++n > 1 }),
      launcher: fakePanel((p) => p.reply({ status: "answered", outcome: "declined" })).launcher,
    });
    expect(raced.outcome).toBe("satisfied");
  }));

  test("timeout cancels the panel and reports expired", () => withDir(async (dir) => {
    let lastControl: any;
    const result = await askOperator(request, {
      ...fast, dir, timeoutMs: 80, check: async () => ({ satisfied: false }),
      launcher: fakePanel(async (p) => {
        for (;;) {
          lastControl = await p.control().catch(() => lastControl);
          if (lastControl?.status === "cancelled") { await p.reply({ status: "answered", outcome: "cancelled" }); return; }
          await new Promise((r) => setTimeout(r, 5));
        }
      }).launcher,
    });
    expect(lastControl.status).toBe("cancelled");
    expect(result.outcome).toBe("cancelled");
  }));

  test("one panel per key: a concurrent caller joins the first", () => withDir(async (dir) => {
    let granted = false;
    const panel = fakePanel(async (p) => {
      await new Promise((r) => setTimeout(r, 40));
      granted = true;
      for (;;) {
        const control = await p.control().catch(() => undefined);
        if (control?.status === "satisfied") { await p.reply({ status: "answered", outcome: "satisfied" }); return; }
        await new Promise((r) => setTimeout(r, 5));
      }
    });
    const options = { ...fast, dir, launcher: panel.launcher, check: async () => ({ satisfied: granted }) };
    const [a, b] = await Promise.all([askOperator(request, options), askOperator(request, options)]);
    expect(panel.launches()).toBe(1);
    expect(a.outcome).toBe("satisfied");
    expect(b).toMatchObject({ outcome: "satisfied", joined: true });
  }));

  test("an Action.app without the panel is unsupported, not a hang", () => withDir(async (dir) => {
    const panel = fakePanel(() => {});
    const result = await askOperator(request, { ...fast, supported: async () => false, dir, launcher: panel.launcher, check: async () => ({ satisfied: false }) });
    expect(result.outcome).toBe("unsupported");
    expect(panel.launches()).toBe(0);
  }));

  test("a host error reply is unsupported with its detail", () => withDir(async (dir) => {
    const result = await askOperator(request, {
      ...fast, dir, check: async () => ({ satisfied: false }),
      launcher: fakePanel((p) => p.reply({ status: "error", detail: "bad pane" })).launcher,
    });
    expect(result).toMatchObject({ outcome: "unsupported", detail: "Action rejected the ask: bad pane" });
  }));

  test("resolution user: Done is confirmed without a check", () => withDir(async (dir) => {
    const result = await askOperator({ ...request, key: "approval:rex", resolution: "user" }, {
      ...fast, dir, launcher: fakePanel((p) => p.reply({ status: "answered", outcome: "confirmed" })).launcher,
    });
    expect(result.outcome).toBe("confirmed");
  }));
});

describe("validateAskRequest", () => {
  const bad: Array<[string, Partial<AskRequest>]> = [
    ["title", { title: " " }],
    ["key", { key: "" }],
    ["four", { steps: Array.from({ length: 5 }, (_, i) => ({ id: `s${i}`, label: "x", action: { kind: "agent" as const } })) }],
    ["pane", { steps: [{ id: "a", label: "x", action: { kind: "open-settings", pane: "bluetooth" as never } }] }],
    ["absolute", { steps: [{ id: "a", label: "x", action: { kind: "reveal", path: "CuaDriver.app" } }] }],
    ["https", { steps: [{ id: "a", label: "x", action: { kind: "open-url", url: "http://example.com" } }] }],
    ["kind", { steps: [{ id: "a", label: "x", action: { kind: "shell" } as never }] }],
    ["item step", { items: [{ id: "i", label: "x", state: "missing" as const, step: "nope" }] }],
    ["subject", { subject: { name: "CuaDriver", path: "CuaDriver.app" } }],
    ["unique", { steps: [{ id: "a", label: "x", action: { kind: "agent" } }, { id: "a", label: "y", action: { kind: "agent" } }] }],
  ];
  for (const [name, patch] of bad) test(`rejects ${name}`, () => {
    expect(() => validateAskRequest({ ...request, ...patch })).toThrow(/Invalid ask/);
  });
  test("accepts the sample", () => expect(() => validateAskRequest(request)).not.toThrow());
});

describe("presets", () => {
  const needs = [
    { kind: "permission" as const, permission: "accessibility" as const, app: "com.trycua.driver", detail: "", fix: "" },
    { kind: "permission" as const, permission: "screen-recording" as const, app: "com.trycua.driver", detail: "", fix: "" },
  ];
  test("permissionAsk builds one keyed ask with settings, reveal and retry steps", () => {
    const ask = permissionAsk("trycua-cua", needs, { appPath: "/Applications/CuaDriver.app", retry: true })!;
    expect(ask.key).toBe("tcc:com.trycua.driver:accessibility+screen-recording");
    expect(ask.title).toBe("Let CuaDriver control this Mac");
    expect(ask.items!.map((item) => item.id)).toEqual(["accessibility", "screen-recording"]);
    expect(ask.steps!.map((step) => step.id)).toEqual(["open-accessibility", "open-screen-recording", "reveal", "retry"]);
    expect(ask.items!.map((item) => item.step)).toEqual(["open-accessibility", "open-screen-recording"]);
    expect(ask.subject).toEqual({ name: "CuaDriver", path: "/Applications/CuaDriver.app" });
    expect(() => validateAskRequest(ask)).not.toThrow();
    expect(permissionAsk("x", [{ kind: "install", detail: "", fix: "" }])).toBeUndefined();
  });
  test("availabilityCheck ticks what is no longer needed", async () => {
    const check = availabilityCheck(async () => ({ ready: false, needs: [needs[1]!] }), ["accessibility", "screen-recording"]);
    expect(await check()).toEqual({ satisfied: false, items: { accessibility: "granted", "screen-recording": "missing" } });
  });
});
