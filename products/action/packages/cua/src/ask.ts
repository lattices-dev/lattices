/**
 * Ask the operator through Action.app. An agent that needs something only the
 * person at the Mac can do (a TCC grant to another app, a setting in another
 * app, an approval) raises one Action panel instead of printing instructions.
 *
 * The agent keeps the verdict. Its check() re-reads the real state; the panel
 * only shows what the control file says and closes as "satisfied" when told.
 * The flow is deterministic:
 *
 *   1. check() first. Already satisfied: nothing is shown.
 *   2. One ask per key, across processes (a lock in asks/). A second caller
 *      for the same key waits on the first one's answer, then checks again.
 *   3. Action.app's `ask-user` host command shows the panel without
 *      activating; check() runs every checkMs and its result is written to
 *      the control file, so the checklist ticks as grants land.
 *   4. The panel's buttons are a closed set (open a Settings pane, reveal or
 *      open an app, open an https URL, or an "agent" step that the caller
 *      handles through onStep, e.g. re-requesting a grant).
 *   5. The answer is satisfied, confirmed, declined, cancelled, expired or
 *      unsupported (an Action.app without the panel). Every ask is appended
 *      to asks/log.jsonl.
 */
import { execFile } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, statSync } from "node:fs";
import { appendFile, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import type { BackendHost, BackendCallInput } from "./host.js";
import type { BackendAvailability, BackendNeed } from "./types.js";

export type AskItemState = "missing" | "granted" | "unknown";
/** `step` links the row to the step that fixes it; the panel shows that step on the row. */
export type AskItem = { id: string; label: string; state: AskItemState; step?: string };
/** The app the operator acts on: the panel shows its icon and lets them drag it into a Settings list. */
export type AskSubject = { name: string; path: string };
export type SettingsPane = "accessibility" | "screen-recording" | "automation" | "input-monitoring" | "full-disk-access" | "login-items";
export type AskStepAction =
  | { kind: "open-settings"; pane: SettingsPane }
  | { kind: "reveal"; path: string }
  | { kind: "open-app"; bundleId?: string; path?: string }
  | { kind: "open-url"; url: string }
  | { kind: "agent" };
export type AskStep = { id: string; label: string; action: AskStepAction };

export type AskRequest = {
  /** Same key, same ask: a second caller joins instead of raising another panel. */
  key: string;
  title: string;
  why: string;
  requester?: { agent?: string; task?: string };
  subject?: AskSubject;
  items?: AskItem[];
  /** At most four buttons. */
  steps?: AskStep[];
  /** verify (default): only check() can satisfy the ask. user: the operator says Done. */
  resolution?: "verify" | "user";
};

export type AskCheck = { satisfied: boolean; items?: Partial<Record<string, AskItemState>>; detail?: string };
export type AskOutcome = "satisfied" | "confirmed" | "declined" | "cancelled" | "expired" | "unsupported";
export type AskResult = {
  outcome: AskOutcome;
  /** False when check() was satisfied before any panel was shown. */
  asked: boolean;
  /** True when this caller waited on another caller's panel for the same key. */
  joined?: boolean;
  id?: string;
  detail?: string;
  steps?: string[];
};

/** Launches `Action ask-user <args>` and returns once the launch is handed off. */
export type AskLauncher = (args: string[]) => Promise<void>;

export type AskOptions = {
  check?: () => Promise<AskCheck>;
  /** An "agent" step was clicked (or any step: every click is reported). */
  onStep?: (stepId: string) => void | Promise<void>;
  signal?: AbortSignal;
  timeoutMs?: number;
  checkMs?: number;
  pollMs?: number;
  /** Action.app; defaults to ACTION_APP, /Applications, ~/Applications. */
  app?: string;
  /** Where asks, locks and the log live; defaults to Action's Application Support. */
  dir?: string;
  /** Test seams. */
  launcher?: AskLauncher;
  supported?: () => Promise<boolean>;
  now?: () => number;
};

const DEFAULT_TIMEOUT_MS = 5 * 60_000;
const DEFAULT_CHECK_MS = 1_500;
const DEFAULT_POLL_MS = 250;
/** The panel's "All set" beat is ~1.2 s; give it room before giving up on a reply. */
const CLOSE_GRACE_MS = 4_000;
const LAUNCH_GRACE_MS = 15_000;
const PANES: ReadonlySet<string> = new Set(["accessibility", "screen-recording", "automation", "input-monitoring", "full-disk-access", "login-items"]);

export function defaultAskDir(): string {
  return join(homedir(), "Library/Application Support/Action/asks");
}

export function resolveActionApp(explicit?: string): string | undefined {
  const candidates = [explicit, process.env.ACTION_APP, "/Applications/Action.app", join(homedir(), "Applications/Action.app")]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0);
  return candidates.find((path) => {
    try { return statSync(path).isDirectory() && existsSync(join(path, "Contents/MacOS/Action")); } catch { return false; }
  });
}

function run(file: string, args: string[], timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(file, args, { encoding: "utf8", timeout: timeoutMs, killSignal: "SIGKILL", maxBuffer: 4 * 1024 * 1024 }, (error, stdout) => {
      if (error) reject(error); else resolve(stdout);
    });
  });
}

/** Whether this Action.app has the panel: its capabilities carry operatorAsk. */
export async function actionAppSupportsAsk(app: string | undefined): Promise<boolean> {
  if (!app) return false;
  try {
    const reply = JSON.parse(await run(join(app, "Contents/MacOS/Action"), ["capabilities"], 10_000)) as Record<string, unknown>;
    return typeof reply.operatorAsk === "number" && reply.operatorAsk >= 1;
  } catch {
    return false;
  }
}

function openLauncher(app: string): AskLauncher {
  // -g: the panel orders itself front without activating Action.
  return async (args) => { await run("/usr/bin/open", ["-n", "-g", app, "--args", "ask-user", ...args], 15_000); };
}

/** The same rules the native panel applies, so a bad request fails here, not on screen. */
export function validateAskRequest(request: AskRequest): void {
  const fail = (message: string): never => { throw new Error(`Invalid ask: ${message}`); };
  if (!request.key?.trim()) fail("key is required.");
  if (!request.title?.trim()) fail("title is required.");
  if (typeof request.why !== "string") fail("why is required.");
  const steps = request.steps ?? [];
  if (steps.length > 4) fail("at most four steps.");
  const ids = new Set<string>();
  for (const step of steps) {
    if (!step.id?.trim() || ids.has(step.id)) fail(`step ids must be unique and nonempty (${JSON.stringify(step.id)}).`);
    ids.add(step.id);
    if (!step.label?.trim()) fail(`step ${step.id} needs a label.`);
    const action = step.action;
    switch (action?.kind) {
      case "open-settings": if (!PANES.has(action.pane)) fail(`unknown settings pane ${JSON.stringify(action.pane)}.`); break;
      case "reveal": if (!action.path?.startsWith("/")) fail(`reveal needs an absolute path.`); break;
      case "open-app":
        if (!action.bundleId?.trim() && !action.path?.startsWith("/")) fail("open-app needs a bundleId or an absolute path.");
        break;
      case "open-url": if (!/^https:\/\//i.test(action.url ?? "")) fail("open-url takes https URLs only."); break;
      case "agent": break;
      default: fail(`unknown step kind ${JSON.stringify((action as { kind?: unknown } | undefined)?.kind)}.`);
    }
  }
  const items = new Set<string>();
  for (const item of request.items ?? []) {
    if (!item.id?.trim() || items.has(item.id)) fail(`item ids must be unique and nonempty (${JSON.stringify(item.id)}).`);
    items.add(item.id);
    if (item.step !== undefined && !ids.has(item.step)) fail(`item ${item.id} links an unknown step ${JSON.stringify(item.step)}.`);
  }
  if (request.subject && (!request.subject.name?.trim() || !request.subject.path?.startsWith("/"))) fail("subject needs a name and an absolute path.");
}

async function writeAtomic(path: string, body: unknown): Promise<void> {
  const temporary = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  await writeFile(temporary, `${JSON.stringify(body)}\n`, "utf8");
  await rename(temporary, path);
}

async function readJson(path: string): Promise<Record<string, unknown> | undefined> {
  try {
    const value = JSON.parse(await readFile(path, "utf8")) as unknown;
    return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
  } catch {
    return undefined;
  }
}

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
}

const OUTCOMES: ReadonlySet<string> = new Set(["satisfied", "confirmed", "declined", "cancelled", "expired"]);
const inFlight = new Map<string, Promise<AskResult>>();

/** Ask once per key in this process; other processes are serialised by the lock in dir. */
export function askOperator(request: AskRequest, options: AskOptions = {}): Promise<AskResult> {
  validateAskRequest(request);
  const dir = options.dir ?? defaultAskDir();
  const flight = `${dir}\0${request.key}`;
  const pending = inFlight.get(flight);
  if (pending) return pending.then(async (result) => ({ ...result, joined: true }));
  const started = ask(request, { ...options, dir }).finally(() => inFlight.delete(flight));
  inFlight.set(flight, started);
  return started;
}

async function ask(request: AskRequest, options: AskOptions & { dir: string }): Promise<AskResult> {
  const now = options.now ?? Date.now;
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const checkMs = options.checkMs ?? DEFAULT_CHECK_MS;
  const pollMs = options.pollMs ?? DEFAULT_POLL_MS;
  const deadline = now() + timeoutMs;
  const signal = options.signal;
  const resolution = request.resolution ?? (options.check ? "verify" : "user");
  const check = options.check;
  if (resolution === "verify" && !check) throw new Error("Invalid ask: resolution verify needs a check().");

  if (check) {
    const first = await check();
    if (first.satisfied) return { outcome: "satisfied", asked: false, ...(first.detail ? { detail: first.detail } : {}) };
  }

  const dir = options.dir;
  await mkdir(dir, { recursive: true });
  const hash = createHash("sha256").update(request.key).digest("hex").slice(0, 16);
  const lock = join(dir, `${hash}.lock`);

  // Another process holds this key: wait for it to finish, then check again.
  let joined = false;
  for (;;) {
    try {
      await mkdir(lock);
      await writeFile(join(lock, "owner"), String(process.pid), "utf8");
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      const owner = Number((await readFile(join(lock, "owner"), "utf8").catch(() => "")).trim());
      if (!Number.isInteger(owner) || owner <= 0 || !alive(owner)) {
        // A crashed owner, or one between mkdir and writing its pid. Give the latter a beat.
        await delay(200);
        const again = Number((await readFile(join(lock, "owner"), "utf8").catch(() => "")).trim());
        if (!Number.isInteger(again) || again <= 0 || !alive(again)) await rm(lock, { recursive: true, force: true });
        continue;
      }
      joined = true;
      if (now() >= deadline) return { outcome: "expired", asked: false, joined, detail: "Another ask for this key was still open." };
      signal?.throwIfAborted();
      await delay(Math.min(pollMs * 4, Math.max(1, deadline - now())), undefined, signal ? { signal } : undefined);
      if (check && (await check()).satisfied) return { outcome: "satisfied", asked: false, joined };
    }
  }

  const id = `ask_${new Date(now()).toISOString().replace(/[-:.TZ]/g, "").slice(0, 14)}_${randomBytes(3).toString("hex")}`;
  const work = join(dir, id);
  const files = {
    request: join(work, "request.json"), control: join(work, "control.json"),
    events: join(work, "events.jsonl"), reply: join(work, "reply.json"),
  };
  const log = (entry: Record<string, unknown>) => appendFile(join(dir, "log.jsonl"), `${JSON.stringify({ at: new Date(now()).toISOString(), id, key: request.key, ...entry })}\n`).catch(() => {});
  const clicked: string[] = [];
  try {
    const app = resolveActionApp(options.app);
    const supported = options.supported ? await options.supported() : await actionAppSupportsAsk(app);
    if (!supported || (!app && !options.launcher)) {
      const detail = app ? `${app} has no ask panel (capabilities.operatorAsk); update Action.app.` : "Action.app is not installed.";
      await log({ outcome: "unsupported", detail });
      return { outcome: "unsupported", asked: false, ...(joined ? { joined } : {}), detail };
    }
    await mkdir(work, { recursive: true });
    const items = (request.items ?? []).map((item) => ({ ...item }));
    let control: { status: "waiting" | "satisfied" | "cancelled"; detail?: string; items: Array<{ id: string; state: AskItemState }> } =
      { status: "waiting", items: items.map(({ id: itemId, state }) => ({ id: itemId, state })) };
    const writeControl = () => writeAtomic(files.control, control);
    await writeAtomic(files.request, {
      schema: 1, id, key: request.key,
      requester: { agent: request.requester?.agent ?? "agent", task: request.requester?.task ?? "" },
      title: request.title, why: request.why, ...(request.subject ? { subject: request.subject } : {}),
      items, steps: request.steps ?? [], resolution,
      expiresAt: new Date(deadline).toISOString(),
    });
    await writeControl();
    await writeFile(files.events, "", "utf8");
    await (options.launcher ?? openLauncher(app!))([
      "--request", files.request, "--control-file", files.control, "--events-file", files.events, "--reply-file", files.reply,
    ]);
    const launchedAt = now();
    await log({ event: "shown", title: request.title, requester: request.requester });

    let nextCheck = now() + checkMs;
    let eventsRead = 0;
    let closingSince: number | undefined;
    let closingOutcome: AskOutcome | undefined;
    let sawPanel = false;
    const finish = async (outcome: AskOutcome, detail?: string): Promise<AskResult> => {
      await log({ outcome, ...(detail ? { detail } : {}), steps: clicked });
      return { outcome, asked: true, id, ...(joined ? { joined } : {}), ...(detail ? { detail } : {}), ...(clicked.length ? { steps: clicked } : {}) };
    };
    const close = async (status: "satisfied" | "cancelled", outcome: AskOutcome, detail?: string) => {
      if (closingSince !== undefined) return;
      control = { status, ...(detail ? { detail } : {}),
        items: status === "satisfied" ? control.items.map((item) => ({ ...item, state: "granted" as const })) : control.items };
      await writeControl();
      closingSince = now();
      closingOutcome = outcome;
    };
    const onAbort = () => { void close("cancelled", "cancelled", "The agent withdrew the ask."); };
    signal?.addEventListener("abort", onAbort, { once: true });
    try {
      for (;;) {
        const reply = await readJson(files.reply);
        if (reply) {
          sawPanel = true;
          if (reply.status === "error") return await finish("unsupported", `Action rejected the ask: ${String(reply.detail ?? "no detail")}`);
          const outcome = typeof reply.outcome === "string" && OUTCOMES.has(reply.outcome) ? reply.outcome as AskOutcome : "declined";
          // A decline that raced a grant is still a grant: the check is the verdict.
          if (outcome === "declined" && check && (await check()).satisfied) return await finish("satisfied", "Satisfied as the panel closed.");
          return await finish(outcome, typeof reply.detail === "string" ? reply.detail : undefined);
        }
        if (closingSince !== undefined && now() - closingSince > CLOSE_GRACE_MS) {
          return await finish(closingOutcome!, "Action did not confirm the panel closed.");
        }

        // Every click is reported; "agent" steps are the caller's to act on.
        const events = await readFile(files.events, "utf8").catch(() => "");
        const lines = events.split("\n");
        const complete = lines.slice(0, -1); // The last piece is "" or a line still being written.
        for (const line of complete.slice(eventsRead)) {
          sawPanel = true;
          try {
            const step = (JSON.parse(line) as { step?: unknown }).step;
            if (typeof step === "string") {
              clicked.push(step);
              await log({ event: "step", step });
              await options.onStep?.(step);
            }
          } catch {}
        }
        eventsRead = complete.length;

        if (closingSince === undefined) {
          if (now() >= deadline) await close("cancelled", "expired", "The ask timed out.");
          else if (!options.launcher && !sawPanel && now() - launchedAt > LAUNCH_GRACE_MS && !existsSync(files.reply) && await panelGone(work)) {
            return await finish("unsupported", "Action.app did not show the ask panel.");
          } else if (check && now() >= nextCheck) {
            nextCheck = now() + checkMs;
            const state = await check().catch((error: unknown) => ({ satisfied: false, detail: error instanceof Error ? error.message : String(error) }) as AskCheck);
            if (state.satisfied) await close("satisfied", "satisfied", state.detail);
            else {
              const next = { status: "waiting" as const, ...(state.detail ? { detail: state.detail } : {}),
                items: control.items.map((item) => ({ ...item, state: state.items?.[item.id] ?? item.state })) };
              if (JSON.stringify(next) !== JSON.stringify(control)) { control = next; await writeControl(); }
            }
          }
        }
        await delay(pollMs);
      }
    } finally {
      signal?.removeEventListener("abort", onAbort);
    }
  } finally {
    await rm(lock, { recursive: true, force: true });
    await rm(work, { recursive: true, force: true });
  }
}

/** The panel reads its request then holds no lock we can see; a missing host process is the only signal. */
async function panelGone(work: string): Promise<boolean> {
  try {
    const out = await run("/usr/bin/pgrep", ["-f", `ask-user --request ${join(work, "request.json")}`], 5_000);
    return !out.trim();
  } catch {
    return true; // pgrep exits 1 when nothing matches.
  }
}

const PANE_LABELS: Record<string, string> = {
  accessibility: "Accessibility", "screen-recording": "Screen Recording", automation: "Automation",
};

function appName(app: string | undefined): string {
  if (!app) return "the app";
  if (app.startsWith("/")) return app.split("/").pop()!.replace(/\.app$/, "");
  return app === "com.trycua.driver" ? "CuaDriver" : app === "com.openai.codex" ? "Codex" : app;
}

/** Panel content for a backend's permission needs. Other need kinds are left to the caller. */
export function permissionAsk(backend: string, needs: BackendNeed[], opts: { appPath?: string; retry?: boolean; requester?: AskRequest["requester"] } = {}): AskRequest | undefined {
  const permissions = needs.filter((need): need is BackendNeed & { permission: NonNullable<BackendNeed["permission"]> } => need.kind === "permission" && !!need.permission);
  if (!permissions.length) return undefined;
  const app = permissions[0]!.app;
  const name = appName(opts.appPath ?? app);
  const unique = [...new Set(permissions.map((need) => need.permission))];
  const steps: AskStep[] = unique.slice(0, 2).map((pane) => ({ id: `open-${pane}`, label: "Open", action: { kind: "open-settings", pane } }));
  if (opts.appPath) steps.push({ id: "reveal", label: `Show ${name} in Finder`, action: { kind: "reveal", path: opts.appPath } });
  if (opts.retry) steps.push({ id: "retry", label: "Ask macOS again", action: { kind: "agent" } });
  return {
    key: `tcc:${app ?? backend}:${[...unique].sort().join("+")}`,
    title: `Let ${name} control this Mac`,
    why: `${backend} works through ${name}. Switch ${name} on in each list.`,
    ...(opts.requester ? { requester: opts.requester } : {}),
    ...(opts.appPath ? { subject: { name, path: opts.appPath } } : {}),
    items: unique.map((pane, index) => ({ id: pane, label: PANE_LABELS[pane] ?? pane, state: "missing" as const, ...(index < 2 ? { step: `open-${pane}` } : {}) })),
    steps: steps.slice(0, 4),
    resolution: "verify",
  };
}

/** A check() from a backend's availability: ready is satisfied, and each missing permission stays unticked. */
export function availabilityCheck(read: () => Promise<BackendAvailability>, items: string[]): () => Promise<AskCheck> {
  return async () => {
    const availability = await read();
    const missing = new Set((availability.needs ?? []).map((need) => need.permission).filter(Boolean) as string[]);
    return {
      satisfied: availability.ready,
      items: Object.fromEntries(items.map((item) => [item, missing.has(item) ? "missing" : "granted"])),
      // The checklist already says what is missing; detail only carries news.
      ...(!availability.ready && !missing.size && availability.reason ? { detail: availability.reason } : {}),
    };
  };
}

const APP_PATHS: Record<string, string> = { "com.trycua.driver": "/Applications/CuaDriver.app" };

/**
 * Ask for whatever permissions a backend still needs, verified by its own
 * availability(). "Ask macOS again" re-runs the backend's setup (one at a time),
 * which is how trycua-cua re-requests CuaDriver's grants.
 */
export async function askForBackend(host: BackendHost, id: string, options: Omit<AskOptions, "check" | "onStep"> & {
  requester?: AskRequest["requester"]; call?: BackendCallInput;
} = {}): Promise<AskResult & { needs?: BackendNeed[] }> {
  const read = () => host.availability(id, { timeoutMs: 20_000, ...options.call });
  const availability = await read();
  if (availability.ready) return { outcome: "satisfied", asked: false };
  const needs = availability.needs ?? [];
  const appPath = needs.map((need) => need.app && (need.app.startsWith("/") ? need.app : APP_PATHS[need.app])).find((path) => path && existsSync(path)) || undefined;
  const canRetry = typeof host.get(id).setup === "function";
  const request = permissionAsk(id, needs, { ...(appPath ? { appPath } : {}), retry: canRetry, ...(options.requester ? { requester: options.requester } : {}) });
  if (!request) return { outcome: "unsupported", asked: false, detail: availability.reason ?? `${id} needs something other than a permission.`, needs };
  let retrying: Promise<unknown> | undefined;
  const result = await askOperator(request, {
    ...options,
    check: availabilityCheck(read, (request.items ?? []).map((item) => item.id)),
    onStep: (step) => {
      if (step !== "retry" || retrying) return;
      const { timeoutMs: _availabilityTimeout, ...call } = options.call ?? {};
      retrying = host.setup(id, { ...call, caller: call.caller ?? "ask" }, { interactive: true })
        .catch(() => {}).finally(() => { retrying = undefined; });
    },
  });
  if (result.outcome === "satisfied" || result.outcome === "confirmed") return result;
  return { ...result, needs: (await read().catch(() => availability)).needs ?? needs };
}
