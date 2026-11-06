/**
 * Action.app's one-shot native host, with no dependency on @action/runtime.
 * options.host / ACTION_NATIVE_HOST selects an executable launcher; otherwise
 * options.app / ACTION_APP, /Applications, ~/Applications, then the running Action supply Action.app.
 * options.apps optionally limits targets to bundle ids. Nothing is installed.
 *
 * Native refs retain observed AX paths when the host advertises path commands.
 * The host validates role, label and frame before acting on that exact path.
 * Older hosts use label dispatch, which requires a unique strict best score
 * across the entire application. Incomplete search coverage and unknown AXHelp
 * on competing nodes remain conservative refusals on those hosts.
 *
 * type/key use the current global keyboard focus (type never sets a ref's value).
 * click/scroll points are macOS screen coordinates, NOT screenshot pixels.
 * scroll amount is pixels (default 100); positive wheel deltas mean up/left.
 * Window-scoped hosts inspect, act on and capture the selected PID/window pair.
 * Legacy screenshots select the largest visible app window, which may differ
 * from the focused AX window; no image-to-AX bounds alignment is claimed.
 * Tiers describe the requested AX/HID primitive. LaunchServices activation is
 * inherited from run-app-host.sh and has not been verified to preserve focus.
 */
import { execFile } from "node:child_process";
import { accessSync, constants, existsSync, readFileSync, statSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { actionAppCandidates, findActionApp } from "./locate.js";
import { recordSetupStep, setupCall, waitForSetupPoll } from "./setup.js";
import type {
  Backend,
  BackendAction as Action,
  BackendAxNode as AxNode,
  BackendCall as Call,
  BackendContext as Ctx,
  BackendAvailability,
  BackendNeed,
  BackendSetupResult,
  BackendSetupStep,
  BackendObservation as Observation,
  BackendTarget as Target,
  BackendTier as Tier,
} from "./types.js";

const MAX_DEPTH = 20;
const MAX_NODES = 12_000;
const HOST_TIMEOUT_MS = 10_000;
const LSAPPINFO = "/usr/bin/lsappinfo";
const SETUP_FIX = "action setup action-cua";
const ACTION_BUNDLE_ID = "dev.lattices.Action";
const PATH_COMMANDS = ["press-accessibility-path", "set-accessibility-value-path", "perform-accessibility-action-path"] as const;
const PATH_UPDATE = "update Action.app for path-addressed actions";

/** Faithful run_via_open -g rules (run-app-host.sh:47–53), kept in one table. */
const BACKGROUND_OPEN_RULES: ReadonlyArray<{ command: string; prefix?: boolean; flag?: string }> = [
  { command: "drape" }, { command: "window-order" }, { command: "click-point" },
  { command: "agent-layer" }, { command: "agent-display" }, { command: "agent-cursor-overlay" },
  { command: "blink-", prefix: true }, { command: "launch-app", flag: "--background" },
  { command: "list-app-windows" },
  ...["inspect-app-ui", ...PATH_COMMANDS, "screenshot-app-window"].map((command) => ({ command, flag: "--window-number" })),
];

type Frame = NonNullable<Observation["bounds"]>;
type NativeRoot = "window" | "application";
type NativeNode = {
  depth: number;
  role: string;
  title?: string | null;
  detail?: string | null;
  identifier?: string | null;
  value?: string | null;
  /** Not emitted by the current host. Absent means unknown, null means known absent. */
  help?: string | null;
  actions: string[];
  settableAttributes: string[];
  enabled?: boolean;
  focused?: boolean;
  frame?: Frame | null;
  path?: string | null;
  root?: NativeRoot | null;
  rootWindow?: { title?: string | null; frame?: Frame | null } | null;
  truncated?: boolean | null;
};
type Kept = {
  observationId: string;
  nodes: NativeNode[];
  refs: Map<string, NativeNode>;
  capped: boolean;
  applicationRoot: boolean;
};
type Launcher = { host: string; app?: string } | { host?: undefined; app: string };
/** In-process test seam, never deserialized from backends.json; returns parsed native JSON. */
type Run = (command: string, args: string[], call: Call) => Promise<unknown>;
type NativeCapabilities = { pathActions: boolean; windowScopedAccessibility: boolean; restoreClick: boolean; version?: string };
type NativeTarget = { bundleId: string; pid?: number; windowNumber?: number };
type NativeWindow = {
  pid: number; bundleId: string; appName: string; windowNumber: number;
  title: string; frame: Frame; onScreen: boolean; layer: number;
};

/** Smallest window, in points per side, listed as a target. */
const MIN_TARGET_WINDOW_SIDE = 100;

function isActionableWindow(window: NativeWindow): boolean {
  return window.frame.width >= MIN_TARGET_WINDOW_SIDE && window.frame.height >= MIN_TARGET_WINDOW_SIDE;
}

/** Preserve only structured host errors, including a launcher's nonzero exit. */
class NativeHostError extends Error {
  constructor(command: string, readonly detail: string) {
    super(`ActionHost ${command} failed: ${detail}. Delivery may be uncertain.`);
  }
}

const PRESSABLE_ROLES = new Set(["button", "checkbox", "link", "menuitem", "popupbutton", "radiobutton"]);
const WRITABLE_ROLES = new Set(["combobox", "searchfield", "textarea", "textfield"]);
const ROLE_ALIASES: Record<string, string> = { input: "textfield", text: "textfield", select: "popupbutton", search: "searchfield" };
const MODIFIERS: Record<string, string> = {
  cmd: "cmd", command: "cmd", meta: "cmd", super: "cmd",
  shift: "shift", opt: "opt", option: "opt", alt: "opt", ctrl: "ctrl", control: "ctrl",
};
const KEY_ALIASES: Record<string, string> = {
  enter: "return", esc: "escape", backspace: "delete", pgup: "pageup", pgdn: "pagedown",
  page_up: "pageup", page_down: "pagedown", arrowup: "up", arrowdown: "down", arrowleft: "left", arrowright: "right",
};
const NAMED_KEYS = new Set([
  "return", "tab", "space", "delete", "escape", "up", "down", "left", "right",
  "home", "end", "pageup", "pagedown", "forwarddelete", ...Array.from({ length: 12 }, (_, i) => `f${i + 1}`),
]);

// Swift String comparisons are canonically equivalent, and its regex uses ICU
// whitespace (including NEL), rather than JavaScript's narrower \s set.
// Foundation's trim set additionally includes ZERO WIDTH SPACE, but not FEFF.
const trimNative = (text: string) => text.replace(/^[\p{White_Space}\u200B]+|[\p{White_Space}\u200B]+$/gu, "");
const normalizedText = (text: string) => trimNative(text)
  .replace(/\p{White_Space}+/gu, " ").toLowerCase().normalize("NFC");
function normalizedRole(role: string): string {
  const normalized = trimNative(role).replace(/^ax/i, "").toLowerCase().replace(/[^a-z0-9]/g, "");
  return ROLE_ALIASES[normalized] ?? normalized;
}
const labelOf = (node: NativeNode) => node.title ?? node.detail ?? node.identifier ?? undefined;
// Keep the observed spelling, matching Swift's accessibilityLabelCandidates order.
const pathLabelOf = (node: NativeNode) => [node.title, node.detail, node.value, node.identifier]
  .find((label): label is string => typeof label === "string" && trimNative(label).length > 0);
const settable = (node: NativeNode) => node.settableAttributes.includes("value") || node.settableAttributes.includes("AXValue");
const isRecord = (value: unknown): value is Record<string, unknown> => Boolean(value && typeof value === "object" && !Array.isArray(value));
const isFrame = (value: unknown): value is Frame => isRecord(value) &&
  ["x", "y", "width", "height"].every((key) => typeof value[key] === "number" && Number.isFinite(value[key]));
const isNativeId = (value: unknown, max: number): value is number => typeof value === "number" && Number.isInteger(value) && value > 0 && value <= max;
function isNativeWindow(value: unknown): value is NativeWindow {
  return isRecord(value) && isNativeId(value.pid, 2_147_483_647) && isNativeId(value.windowNumber, 4_294_967_295)
    && typeof value.bundleId === "string" && value.bundleId.length > 0 && !value.bundleId.includes(":") && value.bundleId.trim() === value.bundleId
    && typeof value.appName === "string" && typeof value.title === "string"
    && isFrame(value.frame) && typeof value.onScreen === "boolean" && value.layer === 0;
}
function isNativeNode(value: unknown): value is NativeNode {
  return isRecord(value) && typeof value.role === "string" && Number.isInteger(value.depth) && Number(value.depth) >= 0
    && ["title", "detail", "identifier", "value", "help"].every((key) => value[key] == null || typeof value[key] === "string")
    && ["enabled", "focused"].every((key) => value[key] == null || typeof value[key] === "boolean")
    && (value.frame == null || isFrame(value.frame))
    && (value.path == null || (typeof value.path === "string" && /^(?:root|(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*))*)$/.test(value.path)))
    && (value.root == null || value.root === "window" || value.root === "application")
    && (value.truncated == null || typeof value.truncated === "boolean")
    && ["actions", "settableAttributes"].every((key) => value[key] === undefined
      || (Array.isArray(value[key]) && value[key].every((item: unknown) => typeof item === "string")));
}

/** Mirrors scoreAccessibilityElement (ActionNativeAutomation.swift:1231–1272). */
function score(node: NativeNode, label: string, role: string, writable: boolean, upperBound = false): number | null {
  const actualRole = normalizedRole(node.role);
  if (actualRole !== normalizedRole(role)) return null; // Role is a filter, not just a bonus.
  const expected = normalizedText(label);
  let best: number | null = upperBound && node.help === undefined ? 100 : null;
  for (const candidate of [node.title, node.detail, node.value, node.identifier, node.help]) {
    if (typeof candidate !== "string" || !normalizedText(candidate)) continue;
    const text = normalizedText(candidate);
    const points = text === expected ? 100
      : text.startsWith(expected) || expected.startsWith(text) ? 84
      : text.includes(expected) || expected.includes(text) ? 72 : null;
    if (points !== null) best = Math.max(best ?? 0, points);
  }
  if (best === null) return null;
  return best + 24 + (writable ? (WRITABLE_ROLES.has(actualRole) ? 28 : -20) : (PRESSABLE_ROLES.has(actualRole) ? 18 : -10));
}

function expand(path: string): string {
  return resolve(path === "~" ? homedir() : path.startsWith("~/") ? join(homedir(), path.slice(2)) : path);
}
function executable(path: string): boolean {
  try { accessSync(path, constants.X_OK); return statSync(path).isFile(); } catch { return false; }
}
function configured(value: unknown): string[] {
  return typeof value === "string" && value.trim() ? [expand(value.trim())] : [];
}

/** lsappinfo list is read-only and includes accessory apps: only Foreground entries are regular apps. */
function parseApps(output: string, generation: string): Target[] {
  const targets: Target[] = [];
  const quoted = (value: string) => {
    try { return JSON.parse(value) as string; } catch { return value.slice(1, -1); }
  };
  for (const block of output.split(/(?=^\s*\d+\)\s+")/m)) {
    if (/\((?:terminated|exited-with-subordinates)\)/.test(block)) continue;
    const header = /^\s*\d+\)\s+("(?:\\.|[^"\\])*")/m.exec(block);
    const bundle = /\bbundleID\s*=\s*("(?:\\.|[^"\\])*")/i.exec(block);
    const pid = /\bpid\s*=\s*(\d+)/.exec(block);
    if (!header || !bundle || !pid || !/\btype\s*=\s*"Foreground"/.test(block)) continue;
    const bundleId = quoted(bundle[1]!);
    if (!bundleId || bundleId.includes(":") || Number(pid[1]) <= 0) continue;
    targets.push({ targetId: `${generation}:${bundleId}`, bundleId, app: quoted(header[1]!), pid: Number(pid[1]) });
  }
  return targets;
}

export function createActionCuaBackend(ctx: Ctx): Backend {
  const options = ctx.options;
  const injected = typeof options.__run === "function" ? options.__run as Run : undefined;
  // Pointer/focus restore after a click: auto (co-driving only), true or false. Set false for a demo.
  const restoreMode = options.restore === true || options.restore === "true" ? "true"
    : options.restore === false || options.restore === "false" ? "false" : "auto";
  const apps = Array.isArray(options.apps) ? new Set(options.apps.map(String).map((id) => id.trim().toLowerCase())) : null;
  const kept = new Map<string, Kept>(); // Only the newest observation per target survives.
  const lifetime = new AbortController();
  let nextObservation = 1;
  let nativeCapabilities: Promise<NativeCapabilities> | undefined;

  function checkCall(call: Call) {
    if (call.signal.aborted || lifetime.signal.aborted || call.deadline <= Date.now()) {
      throw ctx.refuse("unavailable", "action-cua call was cancelled, expired, or disposed before dispatch.");
    }
    if (options.apps !== undefined && !Array.isArray(options.apps)) {
      throw ctx.refuse("unavailable", "options.apps must be an array of bundle ids.");
    }
  }

  function resolveLauncher(): { launcher?: Launcher; reason: string } {
    const hosts = [...configured(options.host), ...configured(process.env.ACTION_NATIVE_HOST)];
    const host = hosts.find(executable);
    const explicit = configured(options.app)[0] ?? configured(process.env.ACTION_APP)[0];
    const bundles = actionAppCandidates(explicit, { running: false });
    // A configured host owns the launch; only without one is the running Action worth a process lookup.
    const app = findActionApp(explicit, { running: !host });
    return {
      ...(host ? { launcher: { host, ...(app ? { app } : {}) } } : app ? { launcher: { app } } : {}),
      reason: `No executable native launcher or runnable Action.app found (checked ${[...hosts, ...bundles, "the running Action"].join(", ")}). Install Action.app or set ACTION_NATIVE_HOST to an executable launcher (or options.host).`,
    };
  }

  function parseTarget(targetId: string): NativeTarget {
    const prefix = `${ctx.generation}:`;
    const parts = targetId.startsWith(prefix) ? targetId.slice(prefix.length).split(":") : [];
    const [bundleId, pidText, windowText] = parts;
    const window = parts.length === 3 && /^[1-9]\d*$/.test(pidText!) && /^[1-9]\d*$/.test(windowText!)
      && isNativeId(Number(pidText), 2_147_483_647) && isNativeId(Number(windowText), 4_294_967_295);
    if (!bundleId || bundleId.trim() !== bundleId || (parts.length !== 1 && !window)) {
      throw ctx.refuse("unknown-target", `${targetId} is not a target of this adapter generation; list targets again.`);
    }
    if (apps && !apps.has(bundleId.toLowerCase())) throw ctx.refuse("unknown-target", `${bundleId} is not in this adapter's options.apps.`);
    return { bundleId, ...(window ? { pid: Number(pidText), windowNumber: Number(windowText) } : {}) };
  }

  function targetArguments(target: NativeTarget): string[] {
    return ["--bundle-id", argument(target.bundleId, "bundle id"),
      ...(target.windowNumber !== undefined ? ["--pid", String(target.pid), "--window-number", String(target.windowNumber)] : [])];
  }

  /** No shell interpolation. Abort kills the child; a launched Action instance may already have acted. */
  function processOutput(file: string, args: string[], call: Call): Promise<string> {
    checkCall(call);
    return new Promise((resolveOutput, reject) => {
      execFile(file, args, { encoding: "utf8", signal: call.signal, timeout: Math.max(1, call.deadline - Date.now()), killSignal: "SIGKILL", maxBuffer: 32 * 1024 * 1024 }, (error, stdout) => {
        if (error) {
          // Spawn failures precede delivery. Everything else can have executed.
          if (error.code === "ENOENT" || error.code === "EACCES") {
            reject(ctx.refuse("unavailable", `Cannot execute ${file}: ${error.code}. Install Action.app or set ACTION_NATIVE_HOST.`));
          } else {
            let reply: unknown;
            try { reply = JSON.parse(stdout) as unknown; } catch {}
            if (isRecord(reply) && reply.status === "error" && typeof reply.detail === "string") {
              reject(new NativeHostError(file, reply.detail));
              return;
            }
            const detail = isRecord(reply) ? reply.detail : undefined;
            reject(new Error(`${file} failed${typeof detail === "string" ? `: ${detail}` : ` (${error.code ?? "cancelled"})`}. Delivery may be uncertain.`));
          }
        } else resolveOutput(stdout);
      });
    });
  }

  async function viaOpen(app: string, command: string, args: string[], call: Call): Promise<unknown> {
    let dir: string;
    try { dir = await mkdtemp(join(tmpdir(), "action-cua-host-")); }
    catch { throw ctx.refuse("unavailable", "Cannot create an Action native reply file in os.tmpdir()."); }
    const replyFile = join(dir, "reply.json");
    try {
      const background = BACKGROUND_OPEN_RULES.some((rule) =>
        (rule.prefix ? command.startsWith(rule.command) : command === rule.command) && (!rule.flag || args.includes(rule.flag)));
      await processOutput("/usr/bin/open", ["-n", ...(background ? ["-g"] : []), app, "--args", command, ...args, "--reply-file", replyFile], call);
      for (;;) {
        // After open has run, cancellation is an uncertain outcome, never a refusal.
        call.signal.throwIfAborted();
        if (Date.now() >= call.deadline) throw new Error(`ActionHost did not write a reply for ${command} within ${HOST_TIMEOUT_MS}ms.`);
        try {
          const text = await readFile(replyFile, "utf8");
          if (text.length) return JSON.parse(text) as unknown; // Swift's writer uses an atomic rename.
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        }
        await delay(Math.min(100, Math.max(1, call.deadline - Date.now())), undefined, { signal: call.signal });
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }

  /** Validation finishes before invoking this boundary; native errors stay plain Errors. */
  async function run(call: Call, command: string, args: string[]): Promise<unknown> {
    checkCall(call);
    const { launcher, reason } = resolveLauncher();
    if (!launcher) throw ctx.refuse("unavailable", reason);
    // A permission prompt can remain on screen while the operator responds.
    const deadline = Math.min(call.deadline, Date.now() + (command === "request" ? 60_000 : HOST_TIMEOUT_MS));
    const signal = AbortSignal.any([call.signal, lifetime.signal, AbortSignal.timeout(Math.max(1, deadline - Date.now()))]);
    const bounded: Call = { ...call, deadline, signal };
    let onAbort: () => void = () => {};
    const aborted = injected ? new Promise<never>((_, reject) => {
      onAbort = () => reject(new Error(`action-cua ${command} cancelled after dispatch; delivery may be uncertain.`));
      signal.addEventListener("abort", onAbort, { once: true });
    }) : undefined;
    try {
      const execute = async () => {
        checkCall(bounded);
        if (injected) return await injected(command, args, bounded);
        if (command === LSAPPINFO) return await processOutput(LSAPPINFO, args, bounded);
        if (launcher.host !== undefined) return JSON.parse(await processOutput(launcher.host, [command, ...args], bounded)) as unknown;
        if (command === "capabilities") return JSON.parse(await processOutput(join(launcher.app, "Contents/MacOS/Action"), [command, ...args], bounded)) as unknown;
        return await viaOpen(launcher.app, command, args, bounded);
      };
      // The real transport observes the signal itself. Await its cleanup so a
      // cancelled open/poll does not return while its reply file is still held.
      const result = aborted ? await Promise.race([execute(), aborted]) : await execute();
      if (isRecord(result) && result.status === "error") throw new NativeHostError(command, String(result.detail ?? "no detail"));
      return result;
    } finally {
      signal.removeEventListener("abort", onAbort);
    }
  }

  async function capabilities(call: Call): Promise<NativeCapabilities> {
    checkCall(call);
    if (!nativeCapabilities) {
      const pending = run(call, "capabilities", []).then((reply) => {
        const commands = isRecord(reply) && Array.isArray(reply.accessibilityPathCommands) ? reply.accessibilityPathCommands : [];
        const version = isRecord(reply) && isRecord(reply.build) && typeof reply.build.version === "string" ? reply.build.version : undefined;
        const restoring = isRecord(reply) && Array.isArray(reply.restoringInputCommands) ? reply.restoringInputCommands : [];
        return { pathActions: PATH_COMMANDS.every((command) => commands.includes(command)),
          windowScopedAccessibility: isRecord(reply) && reply.windowScopedAccessibility === true,
          restoreClick: restoring.includes("click-point"), ...(version ? { version } : {}) };
      });
      nativeCapabilities = pending;
      // A failed/cancelled probe is not a cached declaration of host support.
      void pending.catch(() => { if (nativeCapabilities === pending) nativeCapabilities = undefined; });
    }
    const signal = AbortSignal.any([call.signal, lifetime.signal, AbortSignal.timeout(Math.max(1, Math.min(HOST_TIMEOUT_MS, call.deadline - Date.now())))]);
    let onAbort: () => void = () => {};
    const aborted = new Promise<never>((_, reject) => {
      onAbort = () => reject(new Error("action-cua capabilities cancelled while awaiting discovery."));
      signal.addEventListener("abort", onAbort, { once: true });
      if (signal.aborted) onAbort();
    });
    try {
      // A concurrent caller's deadline/cancellation must not wait on the owner.
      return await Promise.race([nativeCapabilities, aborted]);
    } finally {
      signal.removeEventListener("abort", onAbort);
    }
  }

  function permissionNeeds(snapshot: unknown, app?: string): BackendNeed[] {
    const body = isRecord(snapshot) ? snapshot : {};
    const notes = Array.isArray(body.notes) ? body.notes.filter((note): note is string => typeof note === "string") : [];
    const reportedPath = notes.find((note) => note.startsWith("bundlePath="))?.slice("bundlePath=".length);
    const reportedId = notes.find((note) => note.startsWith("bundleId="))?.slice("bundleId=".length);
    const identity = reportedPath || (reportedId && reportedId !== "unknown" ? reportedId : undefined) || app || ACTION_BUNDLE_ID;
    const permissions = [
      ["accessibility", "accessibility", "Accessibility"],
      ["screen-recording", "screenRecording", "Screen & System Audio Recording"],
    ] as const;
    return permissions.flatMap(([permission, key, pane]): BackendNeed[] => body[key] === "granted" ? [] : [{
      kind: "permission", permission, app: identity,
      detail: `Action.app ${pane} permission is ${body[key] === "denied" ? "denied" : "unknown"}. In System Settings → Privacy & Security → ${pane}, enable Action.app (${identity}). Approve a relaunch if macOS asks.`,
      fix: SETUP_FIX,
    }]);
  }

  async function availability(call: Call): Promise<BackendAvailability> {
    checkCall(call);
    const { launcher, reason } = resolveLauncher();
    if (!launcher) return { ready: false, reason: `${reason} Path actions support is unknown.`, needs: [{ kind: "install", app: ACTION_BUNDLE_ID, detail: `${reason} Get Action.app from https://lattices.dev/action.`, fix: SETUP_FIX }] };
    let version: string | undefined;
    if (launcher.app) {
      const plist = join(launcher.app, "Contents/Info.plist");
      try {
        const xml = readFileSync(plist, "utf8");
        version = /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(xml)?.[1];
        if (!version && xml.startsWith("bplist")) {
          version = (await processOutput("/usr/bin/plutil", ["-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist], call)).trim() || undefined;
        }
      } catch { /* A readable version is optional. */ }
    }
    let pathSupport = "Path actions support is unknown.";
    try {
      const native = await capabilities(call);
      version = native.version ?? version;
      pathSupport = native.pathActions ? "Path actions supported." : `Path actions unsupported; ${PATH_UPDATE}.`;
      const status = await run(call, "status", []);
      checkCall(call);
      const needs = permissionNeeds(status, launcher.app);
      return { ready: needs.length === 0, ...(needs.length ? { reason: `Action.app permissions are missing or unknown. ${pathSupport}`, needs } : {}), ...(version ? { version } : {}) };
    } catch (error) {
      return { ready: false, reason: `${error instanceof Error ? error.message : String(error)} ${pathSupport}`, ...(version ? { version } : {}) };
    }
  }

  async function setup(request: Call, opts: { interactive: boolean }): Promise<BackendSetupResult> {
    const call = setupCall(request);
    const steps: BackendSetupStep[] = [];
    const report = (step: BackendSetupStep) => recordSetupStep(ctx, call, steps, step);
    let status: BackendAvailability = { ready: false };
    const result = (): BackendSetupResult => ({ ready: status.ready, steps, ...(status.needs?.length ? { needs: status.needs } : {}) });
    try {
      status = await availability(call);
      report({ step: "status", status: status.ready ? "done" : "waiting-on-user", detail: status.reason ?? "Action.app has Accessibility and Screen Recording access." });
      checkCall(call);
      if (status.ready) return result();
      if (!status.needs?.some((need) => need.kind === "permission")) {
        report({ step: "verify-installation", status: "failed", detail: status.needs?.map((need) => need.detail).join("\n") || status.reason });
        return result();
      }
      if (!opts.interactive) {
        report({ step: "request", status: "skipped", detail: `Interactive setup is required to show macOS permission dialogs. Run ${SETUP_FIX}.` });
        return result();
      }
      report({ step: "request", status: "waiting-on-user", detail: "Approve Action.app in the macOS Accessibility and Screen Recording dialogs. macOS may ask you to relaunch the app." });
      try {
        const requested = await run(call, "request", []);
        if (!isRecord(requested) || !["granted", "denied"].includes(String(requested.accessibility)) || !["granted", "denied"].includes(String(requested.screenRecording))) {
          throw new Error("ActionHost request returned no valid permission snapshot.");
        }
        report({ step: "request", status: "done", detail: "Action.app requested Accessibility and Screen Recording access." });
      } catch (error) {
        report({ step: "request", status: "failed", detail: error instanceof Error ? error.message : String(error) });
        if (call.signal.aborted || Date.now() >= call.deadline) throw error;
      }
      status = await availability(call);
      report({ step: "status", status: status.ready ? "done" : "waiting-on-user", detail: status.reason ?? "Both permissions are granted." });
      checkCall(call);
      if (status.ready) return result();
      const pending = (status.needs ?? []).filter((need) => need.kind === "permission");
      if (!pending.length) {
        report({ step: "status", status: "failed", detail: status.reason ?? "Cannot verify Action.app permissions." });
        return result();
      }
      for (const need of pending) {
        const command = need.permission === "accessibility" ? "open-accessibility-settings" : "open-screen-recording-settings";
        try {
          const opened = await run(call, command, []);
          if (!isRecord(opened) || opened.status !== "opened") throw new Error(`ActionHost ${command} did not confirm opening System Settings.`);
          report({ step: command, status: "done", detail: need.detail });
        } catch (error) {
          report({ step: command, status: "failed", detail: error instanceof Error ? error.message : String(error) });
          if (call.signal.aborted || Date.now() >= call.deadline) throw error;
        }
      }
      report({ step: "permissions", status: "waiting-on-user", detail: pending.map((need) => need.detail).join("\n") });
      const wait = typeof options.__wait === "function" ? options.__wait as (call: Call) => Promise<void> : waitForSetupPoll;
      while (!status.ready) {
        await wait(call);
        checkCall(call);
        const next = await availability(call);
        checkCall(call);
        if (!next.ready && !next.needs?.length) {
          // A transport failure is not evidence that a permission was granted.
          report({ step: "status", status: "failed", detail: next.reason ?? "Cannot verify Action.app permissions." });
          return result();
        }
        status = next;
      }
      report({ step: "permissions", status: "done", detail: "Verified Action.app Accessibility and Screen Recording access." });
    } catch (error) {
      status = { ...status, ready: false };
      const expired = Date.now() >= call.deadline || (call.signal.aborted && call.signal.reason?.name === "TimeoutError");
      report({ step: "permissions", status: expired && status.needs?.some((need) => need.kind === "permission") ? "waiting-on-user" : "failed",
        detail: expired ? `Setup timed out. Complete the remaining System Settings toggles, then run ${SETUP_FIX}.` : `Setup stopped: ${error instanceof Error ? error.message : String(error)}` });
    }
    return result();
  }

  /** The parser treats --prefixed values as flags; only path value writes accept empty strings. */
  function argument(value: string, name: string, allowEmpty = false): string {
    if (typeof value !== "string" || (!allowEmpty && !value.length) || value.startsWith("--") || value.includes("\0")) {
      throw ctx.refuse("unsupported", `Action's native parser cannot represent an empty, NUL-containing or --prefixed ${name}. Nothing was sent.`);
    }
    return value;
  }

  async function listWindows(call: Call): Promise<NativeWindow[]> {
    const windows = await run(call, "list-app-windows", []);
    if (!Array.isArray(windows) || !windows.every(isNativeWindow)) throw new Error("list-app-windows returned no valid native window array.");
    return windows;
  }

  async function requireWindow(call: Call, targetId: string, target: NativeTarget): Promise<void> {
    if (target.windowNumber === undefined) return;
    if (!(await capabilities(call)).windowScopedAccessibility) {
      throw ctx.refuse("unknown-target", `${targetId} requires window-scoped accessibility support; list targets again.`);
    }
    const windows = await listWindows(call);
    if (!windows.some((window) => window.bundleId === target.bundleId && window.pid === target.pid && window.windowNumber === target.windowNumber)) {
      kept.delete(targetId);
      throw ctx.refuse("unknown-target", `${targetId} is no longer an available window. List targets again; no action was performed.`);
    }
  }

  async function runForTarget(call: Call, targetId: string, target: NativeTarget, command: string, args: string[]): Promise<unknown> {
    try { return await run(call, command, args); }
    catch (error) {
      if (target.windowNumber !== undefined && error instanceof NativeHostError && error.detail.startsWith("window-not-found:")) {
        kept.delete(targetId);
        throw ctx.refuse("unknown-target", `${error.detail} List targets again; no action was performed.`);
      }
      throw error;
    }
  }

  async function observe(call: Call, targetId: string, screenshot: boolean): Promise<Observation> {
    const target = parseTarget(targetId);
    const targetArgs = targetArguments(target);
    const native = await capabilities(call);
    await requireWindow(call, targetId, target);
    const body = await runForTarget(call, targetId, target, "inspect-app-ui", [...targetArgs, "--max-depth", String(MAX_DEPTH), "--max-nodes", String(MAX_NODES), ...(native.pathActions || target.windowNumber !== undefined ? ["--root", "window"] : [])]);
    const raw = Array.isArray(body) ? body : isRecord(body) ? body.nodes : undefined;
    if (!Array.isArray(raw) || !raw.every(isNativeNode)) {
      throw new Error("inspect-app-ui returned no valid accessibility node array.");
    }
    const nodes = raw.slice(0, MAX_NODES).map((node): NativeNode => ({
      ...node,
      // Native snapshot metadata is emitted only on the root node.
      ...(native.pathActions ? { root: node.root ?? raw[0]?.root ?? "window" } : {}),
      actions: Array.isArray(node.actions) ? node.actions.filter((item: unknown) => typeof item === "string") : [],
      settableAttributes: Array.isArray(node.settableAttributes) ? node.settableAttributes.filter((item: unknown) => typeof item === "string") : [],
    }));
    // Both Swift walks are BFS. A stable depth sort also recovers BFS sibling
    // order from a pre-order DFS reply without changing observed native paths.
    nodes.sort((a, b) => a.depth - b.depth);
    const observationId = `${ctx.generation}-${nextObservation++}`;
    const refs = new Map<string, NativeNode>();
    const ax: AxNode[] = nodes.map((node, index) => {
      const ref = `${observationId}:${index}`;
      refs.set(ref, node);
      const label = native.pathActions ? pathLabelOf(node) : labelOf(node);
      return { ref, depth: node.depth, role: node.role, ...(label != null ? { label } : {}),
        ...(node.value != null ? { value: node.value } : {}), actions: [...node.actions], settable: settable(node),
        ...(isFrame(node.frame) ? { frame: { x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height } } : {}) };
    });
    const capped = nodes[0]?.truncated === true || raw.length >= MAX_NODES || (isRecord(body) && (body.truncated === true || body.nodeCapHit === true));
    const applicationRoot = nodes[0]?.depth === 0 && nodes[0]?.role === "AXApplication" && nodes.every((node, i) => node.depth <= MAX_DEPTH && (i === 0 || node.depth > 0));
    kept.set(targetId, { observationId, nodes, refs, capped, applicationRoot });
    let shot: Observation["screenshot"];
    if (screenshot) {
      try { await mkdir(ctx.shotsDir, { recursive: true }); }
      catch { throw ctx.refuse("unavailable", "Cannot create the action-cua screenshot directory."); }
      const path = resolve(ctx.shotsDir, `${observationId}.png`);
      const reply = await runForTarget(call, targetId, target, "screenshot-app-window", [...targetArgs, "--output", path]);
      if (!isRecord(reply) || reply.status !== "screenshot" || (reply.outputPath !== undefined && reply.outputPath !== path) || !existsSync(path) || statSync(path).size === 0) {
        throw new Error("screenshot-app-window did not produce the requested screenshot.");
      }
      shot = { path };
    }
    const window = nodes.find((node) => node.role === "AXWindow" && isFrame(node.frame));
    return { observationId, targetId, at: Date.now(), ax, ...(!shot && window?.frame ? { bounds: { ...window.frame } } : {}), ...(shot ? { screenshot: shot } : {}) };
  }

  async function current(call: Call, targetId: string, observationId: string, ref?: string): Promise<Kept> {
    const target = parseTarget(targetId);
    await requireWindow(call, targetId, target);
    const entry = kept.get(targetId);
    if (!entry || entry.observationId !== observationId || (ref !== undefined && !entry.refs.has(ref))) {
      const fresh = await observe(call, targetId, false);
      throw ctx.refuse("stale-ref", `${ref ?? observationId} is not in the newest observation of this target. Act again from ${fresh.observationId}.`, fresh);
    }
    return entry;
  }

  function semantic(entry: Kept, node: NativeNode, writable: boolean): string {
    const refuse = (message: string) => ctx.refuse("unsupported", `${message} Please ${PATH_UPDATE}.`);
    if (entry.capped) throw refuse("The observation hit the node cap; native label search may see unobserved candidates.");
    const label = labelOf(node);
    if (!label || !normalizedText(label)) throw refuse("This ref has no usable label for native matching.");
    if (!normalizedRole(node.role)) throw refuse("This ref has no usable role for native matching.");
    argument(label, "label");
    argument(node.role, "role");
    const targetScore = score(node, label, node.role, writable);
    if (targetScore === null || entry.nodes.some((other) => other !== node && (score(other, label, node.role, writable, true) ?? -Infinity) >= targetScore)) {
      throw refuse("Ambiguous native label match: another node has an equal or higher score, or its unreported AXHelp could tie. This ref is not the unique strict best.");
    }
    if (!entry.applicationRoot) {
      throw refuse("Incomplete native search coverage: inspect-app-ui is window-rooted, but native label matching searches the whole application. An application-root snapshot with AXHelp evidence is needed to prove an unambiguous ref.");
    }
    return label;
  }

  function pathArguments(target: NativeTarget, node: NativeNode): string[] {
    if (!node.path || !node.root) throw ctx.refuse("unsupported", "This ref has no observed AX path/root. Observe again before acting.");
    const label = pathLabelOf(node);
    return [...targetArguments(target), "--path", node.path, "--root", node.root, "--expect-role", argument(node.role, "role"),
      ...(label !== undefined ? ["--expect-label", argument(label, "label")] : []),
      ...(node.frame ? ["--expect-frame", [node.frame.x, node.frame.y, node.frame.width, node.frame.height].join(",")] : [])];
  }

  function verifyPathMatch(reply: unknown, node: NativeNode, status: string) {
    if (!isRecord(reply) || reply.status !== status || reply.path !== node.path || reply.role !== node.role || reply.root !== node.root) {
      throw new Error("ActionHost path action reply differs from the intended ref; delivery is uncertain.");
    }
  }

  function verifyMatch(reply: unknown, bundleId: string, node: NativeNode, label: string, status: string, action?: string) {
    if (!isRecord(reply) || reply.status !== status) throw new Error("ActionHost returned an unexpected action reply; delivery is uncertain.");
    if (reply.detail != null && typeof reply.detail !== "string") throw new Error("ActionHost returned malformed match detail; delivery is uncertain.");
    // Current host returns only the matched role and ECHOES the requested label.
    // This is a role check, not proof of matched label/frame identity.
    if (typeof reply.detail === "string" && reply.detail !== `${bundleId} ${node.role} ${label}${action ? ` ${action}` : ""}`) {
      throw new Error("ActionHost matched element differs from the intended ref; delivery is uncertain.");
    }
    const matched = reply.element ?? reply.matchedElement ?? reply.match;
    if (matched === undefined) return;
    if (!isRecord(matched)) throw new Error("ActionHost returned malformed matched-element evidence; delivery is uncertain.");
    const returnedLabel = matched.label ?? matched.title ?? matched.detail ?? matched.identifier;
    const returnedFrame = matched.frame;
    const mismatch = (matched.role !== undefined && matched.role !== node.role)
      || (returnedLabel !== undefined && returnedLabel !== label)
      || (returnedFrame != null && (!isFrame(returnedFrame) || !isFrame(node.frame)
        || ["x", "y", "width", "height"].some((key) => returnedFrame[key as keyof Frame] !== node.frame![key as keyof Frame])));
    if (mismatch) throw new Error("ActionHost matched element differs from the intended ref; delivery is uncertain.");
  }

  return {
    schema: 1,
    capabilities: {
      surfaces: ["computer"], observe: { ax: true, screenshot: true },
      actions: { press: "semantic", setValue: "semantic", secondary: "semantic", type: "attention", key: "attention", click: "attention", scroll: "attention" },
    },
    availability,
    setup,
    async targets(call) {
      if ((await capabilities(call)).windowScopedAccessibility) {
        // Apps keep helper windows (1x1 slivers, tab-bar strips, badges, popups) that are not
        // worth acting on. Keep windows of real size, including ones on other Spaces.
        return (await listWindows(call)).filter((window) => (!apps || apps.has(window.bundleId.toLowerCase())) && isActionableWindow(window)).map((window) => ({
          targetId: `${ctx.generation}:${window.bundleId}:${window.pid}:${window.windowNumber}`,
          bundleId: window.bundleId, app: window.appName, title: window.title, pid: window.pid,
        }));
      }
      const output = await run(call, LSAPPINFO, ["list"]);
      if (typeof output !== "string") throw new Error("lsappinfo list returned no text.");
      const listed = parseApps(output, ctx.generation);
      const counts = new Map<string, number>();
      for (const target of listed) counts.set(target.bundleId!, (counts.get(target.bundleId!) ?? 0) + 1);
      return listed.filter((target) => counts.get(target.bundleId!) === 1 && (!apps || apps.has(target.bundleId!.toLowerCase())));
    },
    async observe(call, targetId, opts) { return await observe(call, targetId, opts.screenshot === true); },
    async act(call, targetId, action: Action, opts) {
      checkCall(call);
      const target = parseTarget(targetId);
      const { bundleId } = target;
      argument(bundleId, "bundle id");
      const entry = await current(call, targetId, opts.observationId, "ref" in action ? action.ref : undefined);
      let command: string;
      let args: string[];
      let mechanism: string;
      let tierUsed: Tier = "attention";
      let match: { node: NativeNode; label: string; status: string; action?: string } | undefined;
      let pathMatch: { node: NativeNode; status: string } | undefined;
      switch (action.kind) {
        case "press":
        case "setValue":
        case "secondary": {
          const node = entry.refs.get(action.ref)!;
          const native = await capabilities(call);
          if (target.windowNumber !== undefined && !native.pathActions) {
            throw ctx.refuse("unsupported", `Window targets require path-addressed actions; please ${PATH_UPDATE}.`);
          }
          const label = native.pathActions ? undefined : semantic(entry, node, action.kind === "setValue");
          if (node.enabled === false) throw ctx.refuse("invalid-action", "The observed element is disabled.");
          args = native.pathActions ? pathArguments(target, node) : ["--bundle-id", bundleId, "--label", label!, "--role", node.role];
          tierUsed = "semantic";
          if (action.kind === "setValue") {
            if (!settable(node)) throw ctx.refuse("unsupported", "This ref does not advertise a settable AXValue.");
            args.push("--value", argument(action.value, "value", native.pathActions));
            command = native.pathActions ? "set-accessibility-value-path" : "set-accessibility-value";
            mechanism = native.pathActions ? "ax-path-set-value" : "ax-set-value";
            if (native.pathActions) pathMatch = { node, status: "value-set" };
            else match = { node, label: label!, status: "value-set" };
          } else if (action.kind === "secondary") {
            const name = action.name.startsWith("AX") ? action.name : `AX${action.name}`;
            if (!node.actions.includes(name)) throw ctx.refuse("unsupported", `This ref does not advertise ${name}.`);
            args.push("--action", argument(name, "action"));
            command = native.pathActions ? "perform-accessibility-action-path" : "perform-accessibility-action";
            mechanism = native.pathActions ? "ax-path-action" : `ax-${name}`;
            if (native.pathActions) pathMatch = { node, status: "performed" };
            else match = { node, label: label!, status: "performed", action: name };
          } else {
            if (!node.actions.includes("AXPress")) throw ctx.refuse("unsupported", "This ref does not advertise AXPress.");
            command = native.pathActions ? "press-accessibility-path" : "press-accessibility-element";
            mechanism = native.pathActions ? "ax-path-press" : "ax-press";
            if (native.pathActions) pathMatch = { node, status: "pressed" };
            else match = { node, label: label!, status: "pressed" };
          }
          break;
        }
        case "type":
          if (action.ref) throw ctx.refuse("unsupported", "type-text types into current global focus; type with a ref is unsupported. Use setValue for a semantic value write.");
          command = "type-text"; args = ["--text", argument(action.text, "text")]; mechanism = "hid-type";
          break;
        case "key": {
          const parts = action.combo.split("+").map((part) => part.trim().toLowerCase());
          const raw = parts.pop() ?? "";
          const key = KEY_ALIASES[raw] ?? raw;
          const modifiers = parts.map((part) => MODIFIERS[part]);
          if (modifiers.some((part) => !part) || !(NAMED_KEYS.has(key) || (key.length === 1 && "abcdefghijklmnopqrstuvwxyz0123456789=-][';\\,/.`".includes(key)))) {
            throw ctx.refuse("invalid-action", "Unsupported key combo. Use one native key with cmd, shift, opt or ctrl; unknown native keys would silently type text.");
          }
          command = "press-key"; args = ["--key", key, ...(modifiers.length ? ["--modifiers", modifiers.join(",")] : [])]; mechanism = "hid-key";
          break;
        }
        case "click":
          if ((action.button !== undefined && action.button !== "left") || (action.count !== undefined && action.count !== 1)) {
            throw ctx.refuse("unsupported", "click-point supports only one primary (left) click.");
          }
          if (!Number.isFinite(action.point.x) || !Number.isFinite(action.point.y)) throw ctx.refuse("invalid-action", "click needs finite screen coordinates.");
          command = "click-point"; args = ["--x", String(action.point.x), "--y", String(action.point.y)]; mechanism = "hid-click";
          // Hand the pointer and focus straight back when the host can.
          // auto (default) restores only while a person is co-driving; false suits a clean demo run.
          if ((await capabilities(call)).restoreClick) args.push("--restore", restoreMode);
          break;
        case "scroll": {
          const frame = action.ref ? entry.refs.get(action.ref)?.frame : undefined;
          const point = action.ref ? (isFrame(frame) && frame.width > 0 && frame.height > 0 ? { x: frame.x + frame.width / 2, y: frame.y + frame.height / 2 } : undefined) : action.point;
          if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) throw ctx.refuse("invalid-action", "scroll needs finite screen coordinates or a ref with a nonempty frame.");
          const amount = action.amount ?? 100;
          if (!Number.isFinite(amount) || amount < 0.5 || amount > 2_147_483_647) throw ctx.refuse("invalid-action", "scroll amount must round to positive Int32 pixels.");
          const delta = Math.round(amount);
          if (!["up", "down", "left", "right"].includes(action.direction)) throw ctx.refuse("invalid-action", "Unknown scroll direction.");
          const x = action.direction === "left" ? delta : action.direction === "right" ? -delta : 0;
          const y = action.direction === "up" ? delta : action.direction === "down" ? -delta : 0;
          command = "scroll"; args = ["--x", String(point.x), "--y", String(point.y), "--delta-x", String(x), "--delta-y", String(y)]; mechanism = "hid-scroll";
          break;
        }
        default: throw ctx.refuse("unsupported", "action-cua has no mapping for this action.");
      }
      // current() yields even for a retained snapshot; a concurrent observe may
      // have replaced it in that turn. Recheck before crossing into dispatch.
      if (kept.get(targetId) !== entry) await current(call, targetId, opts.observationId, "ref" in action ? action.ref : undefined);
      let reply: unknown;
      try {
        reply = await run(call, command, args);
      } catch (error) {
        if (pathMatch && error instanceof NativeHostError && error.detail.startsWith("path-mismatch:")) {
          const fresh = await observe(call, targetId, false);
          throw ctx.refuse("stale-ref", `${error.detail} No action was performed. Act again from ${fresh.observationId}.`, fresh);
        }
        throw error;
      }
      if (pathMatch) verifyPathMatch(reply, pathMatch.node, pathMatch.status);
      else if (match) verifyMatch(reply, bundleId, match.node, match.label, match.status, match.action);
      else {
        const expected = { "type-text": "typed", "press-key": "pressed", "click-point": "clicked", scroll: "scrolled" }[command];
        if (!isRecord(reply) || reply.status !== expected) throw new Error(`ActionHost ${command} returned an unexpected reply; delivery is uncertain.`);
      }
      // The host's detail says, for a click, whether focus and pointer were restored (co-driving) or left (clean-run).
      const detail = !pathMatch && !match && isRecord(reply) && typeof reply.detail === "string" && reply.detail ? reply.detail : undefined;
      return { outcome: "dispatched", tierUsed, mechanism, ...(detail ? { message: detail } : {}) };
    },
    async dispose() { lifetime.abort(); kept.clear(); },
  };
}
