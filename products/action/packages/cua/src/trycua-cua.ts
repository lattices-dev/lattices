/**
 * Action computer backend for trycua's Cua Driver (https://github.com/trycua/cua,
 * libs/cua-driver, MIT). Bring-your-own: the operator installs the driver;
 * nothing of it ships with Action. Ported from the arts-mini Scout adapter
 * (~/.openscout/computer-use/trycua.ts, 2026-10-03); the logic is unchanged.
 *
 * Options, in ~/Library/Application Support/Action/backends.json under "trycua-cua" (all optional):
 *   command      path or name of the cua-driver binary. Default: `cua-driver`
 *                on PATH, then $HOME/.local/bin/cua-driver (the installer's
 *                symlink), then /Applications/CuaDriver.app/Contents/MacOS/cua-driver.
 *   args         default ["mcp"]. On macOS `cua-driver mcp` proxies to the
 *                CuaDriver.app daemon (launching it if needed) so the TCC grants
 *                stay with com.trycua.driver. Do not add --direct: that moves
 *                TCC attribution onto Action's MCP process.
 *   maxElements  AX walk cap passed to get_window_state (default 800).
 *   telemetry    true to leave the driver's default-on product telemetry alone.
 *                Default false: CUA_DRIVER_RS_TELEMETRY_ENABLED=false is set on
 *                the process the backend spawns.
 *
 * Driver surface used (MCP over stdio): health_report, list_apps, list_windows,
 * get_window_state, click, set_value, type_text, press_key, hotkey, scroll.
 * The browser_* tools are never called, and delivery_mode is never set, so
 * every call uses the driver's default "background" rung. No retries.
 *
 * Tiers, from the driver source (libs/cua-driver/rust/crates/platform-macos/src):
 *   press     semantic   click{element_token} -> AXPerformAction(AXPress). The
 *                        driver falls back to an AXSelected write and then a
 *                        pid-routed pixel click ONLY when the element does not
 *                        advertise AXPress, so press is refused on any ref whose
 *                        observed actions lack AXPress.
 *   secondary semantic   click{element_token, action: pick|confirm|cancel|open}.
 *                        AXShowMenu is refused: its menu tracking loop takes the
 *                        operator's input.
 *   setValue  semantic   set_value -> AXValue write. The Safari <select> route
 *                        (osascript into the front document) is refused.
 *   type      attention  kAXSelectedText, then AXFocused + CGEvent keystrokes to the pid.
 *   key       attention  press_key / hotkey: CGEvent key events posted to the pid.
 *   click     attention  click{x,y}: synthesized mouse events; activates "without raise".
 *   scroll    attention  AX scroll-bar press, else a wheel event or PageUp/Down.
 *
 * tierUsed is read back from the driver's result (`route` / `delivery.mode`,
 * or the legacy `path`): accessibility in the background is semantic, anything
 * else is attention.
 */

import { spawn } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { recordSetupStep, setupCall, waitForSetupPoll } from "./setup.js";
import { delimiter, join } from "node:path";
import type {
  BackendAvailability,
  Backend,
  BackendNeed,
  BackendSetupResult,
  BackendSetupStep,
  BackendAction as Action,
  BackendAxNode as AxNode,
  BackendCall as Call,
  BackendContext as Ctx,
  BackendObservation as Observation,
  BackendTarget as Target,
  BackendTier as Tier,
  McpClient,
  McpToolResult as ToolResult,
} from "./types.js";

const DRIVER_APP = "com.trycua.driver";
const DRIVER_APP_PATH = "/Applications/CuaDriver.app";
const SETUP_FIX = "action setup trycua-cua";
const SETTINGS_PANES = {
  accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
  "screen-recording": "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
} as const;
type PermissionStatus = { accessibility?: boolean; screen_recording?: boolean; daemon_running?: boolean; status?: string };
type SetupCommandResult = { stdout: string; stderr?: string; exitCode: number | null; timedOut?: boolean };
/** Function-only test seam; backends.json cannot supply executable code. */
type SetupRun = (command: string, args: string[], call: Call, opts: { timeoutMs: number; stream: boolean; onOutput?: (chunk: string) => void }) => Promise<SetupCommandResult>;

function permissionNeeds(status: PermissionStatus = {}): BackendNeed[] {
  const missing: BackendNeed[] = [];
  if (status.status === "unknown" || status.accessibility !== true) missing.push({
    kind: "permission", permission: "accessibility", app: DRIVER_APP, fix: SETUP_FIX,
    detail: "Enable CuaDriver in System Settings → Privacy & Security → Accessibility. If it is absent, click + or drag /Applications/CuaDriver.app from Finder into the list, then enable its switch.",
  });
  if (status.status === "unknown" || status.screen_recording !== true) missing.push({
    kind: "permission", permission: "screen-recording", app: DRIVER_APP, fix: SETUP_FIX,
    detail: "Enable CuaDriver in System Settings → Privacy & Security → Screen & System Audio Recording (Screen Recording). If absent, add /Applications/CuaDriver.app with + or drag it from Finder. Accept Quit & Reopen if macOS asks.",
  });
  return missing;
}

const pendingPermissions = (reason: string) => /permissions_pending|permissions?[^\n]*unknown|status\s*(?:is|[:=])?\s*["']?unknown/i.test(reason);

function which(name: string): string | null {
  for (const dir of (process.env.PATH ?? "").split(delimiter)) {
    if (!dir) continue;
    const path = join(dir, name);
    if (existsSync(path)) return path;
  }
  return null;
}

type DriverElement = {
  element_index: number;
  role: string;
  depth: number;
  element_token?: string;
  label?: string;
  value?: string;
  actions?: string[];
  enabled?: boolean;
  in_web_content?: boolean;
};
type DriverWindowState = {
  pid: number;
  window_id: number;
  snapshot_id?: string;
  app_name?: string;
  window_title?: string;
  elements?: DriverElement[];
  degraded_reason?: string;
  screenshot_width?: number;
  screenshot_height?: number;
  screenshot_scale?: number;
  window_bounds?: { x: number; y: number; width: number; height: number };
};
type DriverWindow = { window_id: number; pid: number | null; app_name: string; title: string; is_on_screen: boolean; z_index: number | null; layer?: number; minimized?: boolean };
type DriverApp = { pid: number; name: string; running: boolean; active: boolean; bundle_id?: string };
type KeptElement = { token?: string; role: string; label?: string; actions: string[] };
type Kept = { key: string; pid: number; windowId: number; bundleId?: string; hasScreenshot: boolean; elements: Map<string, KeptElement> };

const KEEP_OBSERVATIONS = 8;
const MAX_VALUE_CHARS = 200;
const SAFARI_BUNDLES = new Set(["com.apple.Safari", "com.apple.SafariTechnologyPreview"]);
const SECONDARY_ACTIONS: Record<string, string> = {
  AXPress: "press",
  AXPick: "pick",
  AXConfirm: "confirm",
  AXCancel: "cancel",
  AXOpen: "open",
};
const MODIFIERS: Record<string, string> = {
  cmd: "cmd", command: "cmd", super: "cmd", meta: "cmd",
  ctrl: "ctrl", control: "ctrl",
  alt: "option", opt: "option", option: "option",
  shift: "shift",
  fn: "fn",
};
const KEY_NAMES: Record<string, string> = {
  enter: "return", kp_enter: "return", esc: "escape", backspace: "delete",
  pgup: "pageup", page_up: "pageup", prior: "pageup", pgdn: "pagedown", page_down: "pagedown", next: "pagedown",
};

function structured<T>(result: ToolResult): T | null {
  if (result.structuredContent && typeof result.structuredContent === "object") return result.structuredContent as T;
  const text = result.content?.find((item) => item.type === "text")?.text;
  if (!text) return null;
  try {
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}

function text(result: ToolResult): string {
  return (result.content ?? []).filter((item) => item.type === "text").map((item) => item.text ?? "").join("\n").trim();
}

/** A driver refusal promises nothing was delivered (action-result-contract.md: `refused` has neither delivery nor evidence). */
function refusalOf(body: Record<string, any> | null): { code: string; message: string } | null {
  if (!body) return null;
  if (body.status === "refused" && body.refusal?.code) return { code: String(body.refusal.code), message: String(body.refusal.message ?? "") };
  if (body.effect === "refused") {
    const code = body.error?.code ?? body.code ?? "refused";
    return { code: String(code), message: String(body.error?.hint ?? body.summary ?? "") };
  }
  return null;
}

/** Background accessibility is semantic; synthesized events, HID, or any foreground rung is attention. */
function tierFromResult(body: Record<string, any> | null): { tier: Tier; mechanism: string } {
  const route = typeof body?.route === "string" ? body.route : undefined;
  const path = typeof body?.path === "string" ? body.path : undefined;
  const mode = typeof body?.delivery?.mode === "string" ? body.delivery.mode : undefined;
  const foreground = mode === "foreground" || (path?.endsWith("_fg") ?? false);
  const accessibility = route ? route === "accessibility" : path === "ax" || path === "ax_fg";
  const mechanism = `cua:${route ?? path ?? "unknown"}${mode ? `/${mode}` : ""}`;
  if (accessibility && !foreground) return { tier: "semantic", mechanism };
  return { tier: "attention", mechanism };
}

function parseCombo(combo: string): { key: string; modifiers: string[] } {
  const parts = combo.split("+").map((part) => part.trim()).filter(Boolean);
  const raw = (parts.pop() ?? "").toLowerCase();
  const key = KEY_NAMES[raw] ?? raw;
  const modifiers = parts.map((part) => MODIFIERS[part.toLowerCase()] ?? part.toLowerCase());
  return { key, modifiers };
}

export function createTrycuaCuaBackend(ctx: Ctx): Backend {
  const options = ctx.options ?? {};
  const args = Array.isArray(options.args) ? options.args.map(String) : ["mcp"];
  const cwd = typeof options.cwd === "string" ? options.cwd : undefined;
  const maxElements = typeof options.maxElements === "number" && options.maxElements > 0 ? Math.floor(options.maxElements) : 800;
  const env: Record<string, string> = options.telemetry === true ? {} : { CUA_DRIVER_RS_TELEMETRY_ENABLED: "false" };

  let client: Promise<McpClient> | null = null;
  let nextObservation = 1;
  const kept = new Map<string, Kept>();
  const latest = new Map<string, string>(); // target key -> newest observationId (the driver stales older snapshots of a window)
  const known = new Map<string, Target>();
  const lifetime = new AbortController();
  const injectedSetupRun = typeof options.__setupRun === "function" ? options.__setupRun as SetupRun : undefined;
  const poll = typeof options.__setupPoll === "function" ? options.__setupPoll as (call: Call, intervalMs?: number) => Promise<void> : waitForSetupPoll;
  const pauseSetup = async (call: Call, intervalMs = 2_000) => {
    call.signal.throwIfAborted();
    if (call.deadline <= Date.now()) throw new Error("Setup deadline expired.");
    let onAbort = () => {};
    const aborted = new Promise<never>((_, reject) => {
      onAbort = () => reject(call.signal.reason ?? new Error("Setup cancelled."));
      call.signal.addEventListener("abort", onAbort, { once: true });
    });
    try {
      await Promise.race([poll(call, Math.min(intervalMs, call.deadline - Date.now())), aborted]);
      call.signal.throwIfAborted();
      if (call.deadline <= Date.now()) throw new Error("Setup deadline expired.");
    } finally { call.signal.removeEventListener("abort", onAbort); }
  };

  const executeSetup: SetupRun = injectedSetupRun ?? ((command, commandArgs, call, opts) => {
    call.signal.throwIfAborted();
    if (call.deadline <= Date.now()) return Promise.reject(new Error("Setup deadline expired."));
    return new Promise((resolveResult, reject) => {
      const child = spawn(command, commandArgs, { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
      let stdout = "";
      let stderr = "";
      let timedOut = false;
      const timer = setTimeout(() => { timedOut = true; child.kill("SIGKILL"); }, Math.max(1, Math.min(opts.timeoutMs, call.deadline - Date.now())));
      const onAbort = () => { child.kill("SIGKILL"); };
      call.signal.addEventListener("abort", onAbort, { once: true });
      if (call.signal.aborted) onAbort();
      const clean = () => { clearTimeout(timer); call.signal.removeEventListener("abort", onAbort); };
      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => {
        stdout = (stdout + chunk).slice(-1_048_576);
        opts.onOutput?.(chunk);
        if (opts.stream && chunk.trim()) ctx.log(chunk.trimEnd());
      });
      child.stderr.on("data", (chunk: string) => {
        stderr = (stderr + chunk).slice(-1_048_576);
        opts.onOutput?.(chunk);
        if (opts.stream && chunk.trim()) ctx.log(chunk.trimEnd());
      });
      child.once("error", (error) => { clean(); reject(error); });
      child.once("close", (exitCode) => {
        clean();
        if (call.signal.aborted) reject(call.signal.reason ?? new Error("Setup cancelled."));
        else resolveResult({ stdout, stderr, exitCode, ...(timedOut ? { timedOut } : {}) });
      });
    });
  });

  const runSetup: SetupRun = async (command, commandArgs, call, opts) => {
    const check = () => {
      call.signal.throwIfAborted();
      if (call.deadline <= Date.now()) throw new Error("Setup deadline expired.");
    };
    check();
    let onAbort = () => {};
    // The real child observes cancellation and is awaited through close. A
    // function-only test transport also gets a deadline even if it ignores signal.
    const aborted = injectedSetupRun ? new Promise<never>((_, reject) => {
      onAbort = () => reject(call.signal.reason ?? new Error("Setup cancelled."));
      call.signal.addEventListener("abort", onAbort, { once: true });
    }) : undefined;
    try {
      const pending = executeSetup(command, commandArgs, call, { ...opts, timeoutMs: Math.min(opts.timeoutMs, call.deadline - Date.now()) });
      const value = aborted ? await Promise.race([pending, aborted]) : await pending;
      check();
      return value;
    } finally { call.signal.removeEventListener("abort", onAbort); }
  };

  function closeClient() {
    const previous = client;
    client = null;
    // A driver handshake can still be pending. Arrange cleanup when it resolves
    // without making setup or dispose wait past the caller's deadline.
    if (previous) void previous.then((connected) => { try { connected.close(); } catch {} }, () => {});
  }

  async function availabilityOnce(call: Call): Promise<BackendAvailability> {
      const { command, tried } = resolveCommand();
      if (!command) return { ready: false, reason: notInstalled(tried), needs: [{ kind: "install" as const, app: DRIVER_APP, detail: notInstalled(tried), fix: SETUP_FIX }] };
      try {
        const connected = await mcp();
        const report = await read<{
          overall?: string;
          status?: string;
          driver_version?: string;
          checks?: Array<{ name: string; status: string; message?: string; hint?: string }>;
        }>(call, "health_report", {});
        if (Array.isArray(report) || (report.overall !== undefined && typeof report.overall !== "string")
          || (report.status !== undefined && typeof report.status !== "string")
          || (report.checks !== undefined && (!Array.isArray(report.checks)
          || report.checks.some((check) => !check || typeof check.name !== "string" || typeof check.status !== "string")))) {
          return { ready: false, reason: "cua-driver permission status unknown: malformed health report.", needs: permissionNeeds() };
        }
        const version = report.driver_version ?? connected.serverInfo?.version;
        const failed = (report.checks ?? []).filter((check) => check.status === "fail");
        const blocking = failed.filter((check) =>
          ["binary_version", "platform_supported", "session_active", "tcc_accessibility", "tcc_screen_recording", "ax_capability"].includes(check.name));
        const permissionChecks = (report.checks ?? []).filter((check) => ["tcc_accessibility", "tcc_screen_recording"].includes(check.name));
        const missing = permissionChecks.filter((check) => check.status !== "pass");
        const unknown = (!report.overall && !report.status) || report.overall === "unknown" || report.status === "unknown";
        const needs = unknown ? permissionNeeds() : missing.length ? permissionNeeds({
          accessibility: !missing.some((check) => check.name === "tcc_accessibility"),
          screen_recording: !missing.some((check) => check.name === "tcc_screen_recording"),
        }) : [];
        if (report.overall === "failed" || blocking.length || needs.length || report.overall === "permissions_pending" || report.status === "permissions_pending") {
          const detail = (blocking.length ? blocking : failed)
            .map((check) => `${check.name}: ${check.message ?? "fail"}${check.hint ? ` (${check.hint})` : ""}`).join("; ");
          const reason = `cua-driver health ${report.overall ?? report.status ?? "failed"}: ${detail || "permission status unknown"}`;
          return { ready: false, reason, ...(version ? { version } : {}), ...(needs.length ? { needs } : pendingPermissions(reason) ? { needs: permissionNeeds() } : {}) };
        }
        return {
          ready: true,
          ...(failed.length ? { reason: `degraded: ${failed.map((check) => `${check.name}: ${check.message ?? "fail"}`).join("; ")}` } : {}),
          ...(version ? { version } : {}),
        };
      } catch (error) {
        const reason = error instanceof Error ? error.message : String(error);
        return { ready: false, reason, ...(pendingPermissions(reason) ? { needs: permissionNeeds() } : {}) };
      }
  }

  function resolveCommand(): { command: string | null; tried: string[] } {
    const configured = typeof options.command === "string" && options.command.trim() ? options.command.trim() : null;
    const home = process.env.HOME;
    const candidates = configured
      ? [configured]
      : ["cua-driver", ...(home ? [`${home}/.local/bin/cua-driver`] : []), "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"];
    for (const candidate of candidates) {
      if (candidate.includes("/")) {
        const path = candidate.startsWith("~/") && home ? `${home}${candidate.slice(1)}` : candidate;
        if (existsSync(path)) return { command: path, tried: candidates };
      } else {
        const found = which(candidate);
        if (found) return { command: found, tried: candidates };
      }
    }
    return { command: null, tried: candidates };
  }

  const notInstalled = (tried: string[]) =>
    `Cua Driver not found (looked for ${tried.join(", ")}). Install it (operator step): ` +
    `https://cua.ai/docs/cua-driver/quickstart, then run ${SETUP_FIX}; ` +
    `or set options.command to the cua-driver binary.`;

  const mcp = () => {
    if (lifetime.signal.aborted) throw ctx.refuse("unavailable", "trycua-cua backend has been disposed.");
    if (!client) {
      const { command, tried } = resolveCommand();
      if (!command) throw ctx.refuse("unavailable", notInstalled(tried));
      const connecting = ctx.stdioMcp({ command, args, env, cwd, timeoutMs: 30_000 }).catch((error) => {
        if (client === connecting) client = null;
        throw error;
      });
      client = connecting;
    }
    return client;
  };

  const timeoutFor = (call: Call) => Math.max(1_000, call.deadline - Date.now());

  /** Raw call: returns the result whether or not it is an error. */
  const raw = async (call: Call, name: string, toolArgs: Record<string, unknown>) =>
    await (await mcp()).callTool(name, toolArgs, { signal: call.signal, timeoutMs: timeoutFor(call) });

  /** Read-only call: any error is a plain failure. */
  const read = async <T>(call: Call, name: string, toolArgs: Record<string, unknown>): Promise<T> => {
    const result = await raw(call, name, toolArgs);
    const body = structured<T & Record<string, any>>(result);
    if (result.isError || !body) {
      const refusal = refusalOf(body);
      const message = `cua-driver ${name} failed: ${refusal ? `${refusal.code}: ${refusal.message}` : text(result).slice(0, 300) || "no structured result"}`;
      if (refusal?.code === "window_id_not_found" || refusal?.code === "window_not_found" || refusal?.code === "window_owner_pid_mismatch") {
        throw ctx.refuse("unknown-target", message);
      }
      if (refusal) throw ctx.refuse("unavailable", message);
      throw new Error(message);
    }
    return body;
  };

  const keyOf = (pid: number, windowId: number) => `${pid}:${windowId}`;
  const targetIdOf = (pid: number, windowId: number) => `${ctx.generation}:${pid}:${windowId}`;

  const parseTarget = (targetId: string): { pid: number; windowId: number; key: string } => {
    const [generation, pid, windowId, ...rest] = targetId.split(":");
    const p = Number(pid);
    const w = Number(windowId);
    if (generation !== ctx.generation || rest.length || !Number.isInteger(p) || p <= 0 || !Number.isInteger(w) || w <= 0) {
      throw ctx.refuse("unknown-target", `${targetId} is not a target of this adapter generation; list targets again.`);
    }
    return { pid: p, windowId: w, key: keyOf(p, w) };
  };

  async function listTargets(call: Call): Promise<Target[]> {
    const [{ windows }, { apps }] = await Promise.all([
      read<{ windows: DriverWindow[] }>(call, "list_windows", {}),
      read<{ apps: DriverApp[] }>(call, "list_apps", {}),
    ]);
    const byPid = new Map(apps.filter((app) => app.running).map((app) => [app.pid, app]));
    const out: Target[] = [];
    for (const window of windows) {
      if (window.pid == null || (window.layer ?? 0) !== 0) continue;
      const app = byPid.get(window.pid);
      const target: Target = {
        targetId: targetIdOf(window.pid, window.window_id),
        app: app?.name ?? window.app_name,
        ...(app?.bundle_id ? { bundleId: app.bundle_id } : {}),
        ...(window.title ? { title: window.title } : {}),
        pid: window.pid,
        focused: Boolean(app?.active) && window.is_on_screen,
      };
      known.set(keyOf(window.pid, window.window_id), target);
      out.push(target);
    }
    return out;
  }

  async function observeWindow(call: Call, pid: number, windowId: number, screenshot: boolean): Promise<Observation> {
    const args = { pid, window_id: windowId, include_screenshot: screenshot, max_elements: maxElements };
    // cua-driver 0.38 answers in Markdown unless asked for the elements array;
    // drivers older than tree_format reject the field, so ask again without it.
    let result = await raw(call, "get_window_state", { ...args, tree_format: "elements" });
    if (result.isError && /tree_format/.test(text(result))) result = await raw(call, "get_window_state", args);
    const body = structured<DriverWindowState & Record<string, any>>(result);
    if (result.isError || !body) {
      const refusal = refusalOf(body);
      const message = `cua-driver get_window_state failed: ${refusal ? `${refusal.code}: ${refusal.message}` : text(result).slice(0, 300)}`;
      if (refusal && /window_id_not_found|window_not_found|window_owner_pid_mismatch/.test(refusal.code)) throw ctx.refuse("unknown-target", message);
      if (refusal) throw ctx.refuse("unavailable", message);
      throw new Error(message);
    }
    const key = keyOf(pid, windowId);
    const observationId = `${ctx.generation}-${nextObservation++}`;
    const elements = new Map<string, KeptElement>();
    const ax: AxNode[] = (body.elements ?? []).map((element) => {
      const ref = `${observationId}.${element.element_index}`;
      const actions = element.actions ?? [];
      elements.set(ref, { token: element.element_token, role: element.role, label: element.label, actions });
      const value = typeof element.value === "string" && element.value ? element.value.slice(0, MAX_VALUE_CHARS) : undefined;
      return {
        ref,
        depth: element.depth,
        role: element.role,
        ...(element.label ? { label: element.label } : {}),
        ...(value ? { value } : {}),
        ...(actions.length ? { actions } : {}),
      };
    });

    let shot: Observation["screenshot"];
    if (screenshot) {
      const image = result.content?.find((item) => item.type === "image" && item.data);
      if (image?.data) {
        const ext = image.mimeType === "image/jpeg" ? "jpg" : "png";
        const path = `${ctx.shotsDir}/${observationId}.${ext}`;
        writeFileSync(path, Buffer.from(image.data, "base64"));
        shot = {
          path,
          ...(body.screenshot_width ? { width: body.screenshot_width } : {}),
          ...(body.screenshot_height ? { height: body.screenshot_height } : {}),
        };
      }
    }

    const target = known.get(key);
    kept.set(observationId, { key, pid, windowId, bundleId: target?.bundleId, hasScreenshot: Boolean(shot), elements });
    latest.set(key, observationId);
    while (kept.size > KEEP_OBSERVATIONS) kept.delete(kept.keys().next().value!);
    if (body.degraded_reason) ctx.log(`get_window_state ${key} degraded: ${body.degraded_reason}`);

    return {
      observationId,
      targetId: targetIdOf(pid, windowId),
      at: Date.now(),
      ...(body.window_bounds ? { bounds: body.window_bounds } : {}),
      ...(typeof body.screenshot_scale === "number" ? { scale: body.screenshot_scale } : {}),
      ax,
      ...(shot ? { screenshot: shot } : {}),
    };
  }

  /** The observation an act names, which must be the newest one for its window: the driver stales tokens from older snapshots. */
  async function observationFor(call: Call, target: { pid: number; windowId: number; key: string }, observationId: string): Promise<Kept> {
    const observation = kept.get(observationId);
    if (!observation || observation.key !== target.key || latest.get(target.key) !== observationId) {
      const fresh = await observeWindow(call, target.pid, target.windowId, false);
      throw ctx.refuse("stale-ref", `${observationId} is not the current observation of this window; act again from ${fresh.observationId}.`, fresh);
    }
    return observation;
  }

  function elementFor(observation: Kept, observationId: string, ref: string): KeptElement & { token: string } {
    const element = ref.startsWith(`${observationId}.`) ? observation.elements.get(ref) : undefined;
    if (!element) throw ctx.refuse("stale-ref", `${ref} is not an element of observation ${observationId}.`);
    if (!element.token) throw ctx.refuse("invalid-action", `${ref} (${element.role}) is not actionable: the driver gave it no element_token.`);
    return element as KeptElement & { token: string };
  }

  /** Mutating call. A driver refusal becomes a backend refusal (nothing happened); any other error stays an error (outcome unknown). */
  async function act(call: Call, target: { pid: number; windowId: number }, name: string, toolArgs: Record<string, unknown>) {
    const result = await raw(call, name, toolArgs);
    const body = structured<Record<string, any>>(result);
    const refusal = refusalOf(body);
    if (refusal) {
      const message = `cua-driver ${name} refused: ${refusal.code}${refusal.message ? `: ${refusal.message}` : ""}`;
      if (refusal.code === "stale_element_token" || refusal.code === "session_ended") {
        const fresh = await observeWindow(call, target.pid, target.windowId, false);
        throw ctx.refuse("stale-ref", `${message}. Act again from ${fresh.observationId}.`, fresh);
      }
      if (/window_id_not_found|window_not_found|window_target_not_found|window_owner_pid_mismatch/.test(refusal.code)) {
        throw ctx.refuse("unknown-target", message);
      }
      if (refusal.code === "invalid_arguments") throw ctx.refuse("invalid-action", message);
      throw ctx.refuse("unavailable", message);
    }
    if (result.isError) {
      throw new Error(`cua-driver ${name} failed: ${text(result).slice(0, 300) || "error without detail"}`);
    }
    const { tier, mechanism } = tierFromResult(body);
    const effect = typeof body?.effect === "string" ? body.effect : undefined;
    return {
      outcome: "dispatched" as const,
      tierUsed: tier,
      mechanism,
      ...(effect && effect !== "confirmed" ? { message: `driver effect: ${effect}` } : {}),
    };
  }

  return {
    schema: 1 as const,
    capabilities: {
      surfaces: ["computer"] as ["computer"],
      observe: { ax: true, screenshot: true },
      actions: {
        press: "semantic",
        setValue: "semantic",
        secondary: "semantic",
        type: "attention",
        key: "attention",
        click: "attention",
        scroll: "attention",
      } as Partial<Record<Action["kind"], Tier>>,
    },

    async availability(call: Call) {
      const first = await availabilityOnce(call);
      // CuaDriver restarts its daemon after a grant, which ends our cua-driver
      // child. A cached client to a dead child fails forever, so reconnect once.
      if (first.ready || !/exited \(|\bclosed\b|control session/i.test(first.reason ?? "")) return first;
      closeClient();
      return availabilityOnce(call);
    },

    async setup(originalCall, opts): Promise<BackendSetupResult> {
      const call = setupCall({ ...originalCall, signal: AbortSignal.any([originalCall.signal, lifetime.signal]) });
      const steps: BackendSetupStep[] = [];
      const add = (step: BackendSetupStep) => recordSetupStep(ctx, call, steps, step);
      const { command, tried } = resolveCommand();
      if (!command) {
        const detail = notInstalled(tried);
        add({ step: "find-driver", status: "failed", detail });
        return { ready: false, steps, needs: [{ kind: "install", app: DRIVER_APP, detail, fix: SETUP_FIX }] };
      }
      let status: PermissionStatus = {};
      let verified = false;
      const grantController = new AbortController();
      const watchController = new AbortController();
      const grantCall = { ...call, signal: AbortSignal.any([call.signal, grantController.signal]) };
      const watchCall = { ...call, signal: AbortSignal.any([call.signal, watchController.signal]) };
      let grantTask: Promise<{ kind: "grant"; verified: boolean }> | undefined;
      let watchTask: Promise<{ kind: "status" } | { kind: "error"; error: unknown }> | undefined;
      let dialogAppeared!: () => void;
      const dialog = new Promise<{ kind: "dialog" }>((resolve) => { dialogAppeared = () => resolve({ kind: "dialog" }); });
      let progress = "";
      const readStatus = async (request = call) => {
        status = {}; // A failed recheck must not retain an earlier grant.
        const result = await runSetup(command, ["permissions", "status", "--json"], request, { timeoutMs: 10_000, stream: false });
        request.signal.throwIfAborted();
        if (result.exitCode !== 0 || result.timedOut) throw new Error(`Permission status failed: ${result.stderr || result.stdout || "timed out or exited without status"}`);
        const parsed = JSON.parse(result.stdout) as PermissionStatus | null;
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("Permission status returned no JSON object.");
        status = {
          ...(typeof parsed.accessibility === "boolean" ? { accessibility: parsed.accessibility } : {}),
          ...(typeof parsed.screen_recording === "boolean" ? { screen_recording: parsed.screen_recording } : {}),
          ...(typeof parsed.daemon_running === "boolean" ? { daemon_running: parsed.daemon_running } : {}),
          ...(typeof parsed.status === "string" ? { status: parsed.status } : {}),
        };
      };
      const grant = async (verification: boolean, request = call) => {
        const step = verification ? "verify-capture" : "request-permissions";
        add({ step, status: "waiting-on-user", detail: verification
          ? "CuaDriver is verifying capture. Approve its direct screen capture dialog if macOS shows one."
          : "CuaDriver is requesting Accessibility and Screen Recording. Approve the CuaDriver dialogs and enable its switches in System Settings." });
        const result = await runSetup(command, ["permissions", "grant"], request, {
          timeoutMs: verification ? 10_000 : request.deadline - Date.now(), stream: true,
          onOutput: (chunk) => {
            progress = (progress + chunk).slice(-2_048);
            if (/dialog[^\n]*will appear/i.test(progress)) dialogAppeared();
          },
        });
        request.signal.throwIfAborted();
        let verified = result.exitCode === 0 && !result.timedOut;
        // A successful process can still explicitly report a failed capture probe.
        try {
          const detail = JSON.parse(result.stdout);
          if (detail.screen_recording_capturable === false || (detail.direct_capture_status && detail.direct_capture_status !== "ready")) verified = false;
        } catch { /* The CLI also prints human-readable progress. Its exit status is authoritative. */ }
        add({ step, status: verified ? "done" : "waiting-on-user", detail: verified
          ? "CuaDriver completed its permission and capture verification."
          : `CuaDriver still needs approval${result.timedOut ? " (the grant command timed out)" : ""}. ${result.stderr?.trim() || result.stdout.trim() || "Enable its permission switches, then approve the capture dialog."}` });
        return verified;
      };
      try {
        call.signal.throwIfAborted();
        if (!opts.interactive) add({ step: "request-permissions", status: "skipped", detail: `Interactive setup is disabled; run ${SETUP_FIX} to request macOS permission dialogs.` });
        try { await readStatus(); }
        catch (error) {
          if (call.signal.aborted) throw error;
          add({ step: "permission-status", status: "failed", detail: error instanceof Error ? error.message : String(error) });
        }
        let needs = permissionNeeds(status);
        add({ step: "permission-status", status: needs.length ? "waiting-on-user" : "done", detail: needs.length ? "CuaDriver permissions are missing or unknown." : "Accessibility and Screen Recording are granted to CuaDriver." });
        if (!opts.interactive) return { ready: needs.length === 0, steps, ...(needs.length ? { needs } : {}) };
        if (status.daemon_running && needs.length) {
          // An already-running daemon cannot re-prompt. Grant must relaunch it
          // through LaunchServices so the dialogs belong to CuaDriver.app.
          const stopped = await runSetup(command, ["stop"], call, { timeoutMs: 10_000, stream: false });
          const done = stopped.exitCode === 0 && !stopped.timedOut;
          add({ step: "restart-driver", status: done ? "done" : "failed", detail: done
            ? "Stopped CuaDriver so permissions grant can relaunch it and request macOS permissions."
            : `Could not stop CuaDriver. ${stopped.stderr || stopped.stdout}` });
          if (!done) throw new Error("Could not restart CuaDriver to request permissions.");
          closeClient();
        }
        // Observe the rejection immediately, but do not wait for the operator
        // before opening the panes and revealing the app they need to approve.
        grantTask = grant(false, grantCall).then((verified) => ({ kind: "grant" as const, verified }), (error) => {
          if (!grantCall.signal.aborted) add({ step: "request-permissions", status: "failed", detail: error instanceof Error ? error.message : String(error) });
          return { kind: "grant" as const, verified: false };
        });
        if (needs.length) {
          const startup = new AbortController();
          const startupCall = { ...call, signal: AbortSignal.any([call.signal, startup.signal]) };
          // Leave time for the panes even when the caller supplies a short budget.
          const delay = pauseSetup(startupCall, Math.min(3_000, Math.max(0, (call.deadline - Date.now()) / 4)))
            .then(() => ({ kind: "delay" as const }), (error: unknown) => ({ kind: "error" as const, error }));
          try {
            const first = await Promise.race([grantTask, dialog, delay]);
            if (first.kind === "error") throw first.error;
            if (first.kind === "grant") verified = first.verified;
          } finally { startup.abort(); await delay; }
        }
        if (needs.length && !verified) {
          for (const need of needs) {
            const pane = SETTINGS_PANES[need.permission as keyof typeof SETTINGS_PANES];
            add({ step: `open-${need.permission}-settings`, status: "waiting-on-user", detail: need.detail });
            const opened = await runSetup("/usr/bin/open", [pane], call, { timeoutMs: 10_000, stream: false });
            if (opened.exitCode !== 0 || opened.timedOut) add({ step: `open-${need.permission}-settings`, status: "failed", detail: `Could not open System Settings. ${need.detail}` });
          }
          const revealed = await runSetup("/usr/bin/open", ["-R", DRIVER_APP_PATH], call, { timeoutMs: 10_000, stream: false });
          add({ step: "reveal-driver", status: revealed.exitCode === 0 && !revealed.timedOut ? "waiting-on-user" : "failed", detail: "Add /Applications/CuaDriver.app to each missing permission list using + or drag it from Finder. Enable the switches. Accept Quit & Reopen if macOS asks." });
        }
        if (needs.length && !verified) {
          watchTask = (async () => {
            while (true) {
              await pauseSetup(watchCall);
              try { await readStatus(watchCall); }
              catch (error) {
                if (watchCall.signal.aborted || Date.now() >= call.deadline) throw error;
                ctx.log("Waiting for CuaDriver permission status:", error instanceof Error ? error.message : String(error));
                continue;
              }
              watchCall.signal.throwIfAborted();
              if (!permissionNeeds(status).length) break;
            }
            add({ step: "permission-status", status: "done", detail: "Both CuaDriver permission switches are now enabled." });
            return { kind: "status" as const };
          })().catch((error: unknown) => ({ kind: "error" as const, error }));
          const first = await Promise.race([grantTask, watchTask]);
          if (first.kind === "error") throw first.error;
          if (first.kind === "grant") verified = first.verified;
          if (!verified) {
            const checked = await watchTask;
            if (checked.kind === "error") throw checked.error;
            needs = permissionNeeds(status);
          }
        } else if (!verified) verified = (await grantTask).verified;
        if (!verified) {
          // A status result can beat the blocking grant. Reap that process
          // before the one short verification attempt; never run two grants.
          grantController.abort();
          verified = (await grantTask).verified;
          if (!verified) verified = await grant(true);
          if (!verified) { await readStatus(); needs = permissionNeeds(status); }
        }
        if (verified) {
          // Reconnect after a grant/relaunch so later calls cannot retain a stale daemon connection.
          call.signal.throwIfAborted();
          if (Date.now() >= call.deadline) throw new Error("Setup deadline expired.");
          closeClient();
          add({ step: "ready", status: "done", detail: "CuaDriver permissions and capture verification completed." });
          return { ready: true, steps };
        }
        if (!needs.length) needs = [{ kind: "approval", app: DRIVER_APP, detail: "CuaDriver still needs successful direct screen capture verification. Approve its capture dialog, then rerun setup.", fix: SETUP_FIX }];
        add({ step: "wait-for-permissions", status: "waiting-on-user", detail: needs.map((need) => need.detail).join(" ") });
        return { ready: false, steps, needs };
      } catch (error) {
        const needs = permissionNeeds(status);
        const detail = call.signal.aborted || Date.now() >= call.deadline
          ? "Setup stopped or reached its timeout. Enable CuaDriver's permission switches and run setup again."
          : error instanceof Error ? error.message : String(error);
        add({ step: "wait-for-permissions", status: call.signal.aborted || Date.now() >= call.deadline ? "waiting-on-user" : "failed", detail });
        return { ready: false, steps, needs: needs.length ? needs : [{ kind: "approval", app: DRIVER_APP, detail: "CuaDriver capture verification has not completed. Rerun setup and approve its capture dialog.", fix: SETUP_FIX }] };
      } finally {
        grantController.abort();
        watchController.abort();
        await Promise.all([grantTask, watchTask]);
      }
    },

    async targets(call: Call) {
      return await listTargets(call);
    },

    async observe(call: Call, targetId: string, opts: { screenshot?: boolean }) {
      const target = parseTarget(targetId);
      if (!known.has(target.key)) await listTargets(call).catch(() => undefined);
      return await observeWindow(call, target.pid, target.windowId, opts?.screenshot === true);
    },

    async act(call: Call, targetId: string, action: Action, opts: { observationId: string; allowTiers: Tier[] }) {
      const target = parseTarget(targetId);
      const observation = await observationFor(call, target, opts.observationId);
      const base = { pid: target.pid, window_id: target.windowId };

      switch (action.kind) {
        case "press": {
          const element = elementFor(observation, opts.observationId, action.ref);
          // Without an advertised AXPress the driver's click crosses to an
          // AXSelected write and then a pid-routed pixel click (click.rs
          // perform_ax_click). Refuse rather than let it climb past semantic.
          if (!element.actions.includes("AXPress")) {
            throw ctx.refuse("unsupported", `${action.ref} (${element.role}) does not advertise AXPress, so the driver would fall back to a pixel click; use click at a point (attention) instead.`);
          }
          return await act(call, target, "click", { pid: target.pid, element_token: element.token, action: "press" });
        }
        case "secondary": {
          const element = elementFor(observation, opts.observationId, action.ref);
          const mapped = SECONDARY_ACTIONS[action.name];
          if (!mapped) {
            throw ctx.refuse("unsupported", `cua-driver reaches only ${Object.keys(SECONDARY_ACTIONS).join(", ")} as named AX actions here${action.name === "AXShowMenu" ? "; AXShowMenu is refused because the context menu it opens takes the operator's input" : ""}.`);
          }
          if (!element.actions.includes(action.name)) {
            throw ctx.refuse("invalid-action", `${action.ref} (${element.role}) does not advertise ${action.name}.`);
          }
          return await act(call, target, "click", { pid: target.pid, element_token: element.token, action: mapped });
        }
        case "setValue": {
          const element = elementFor(observation, opts.observationId, action.ref);
          if (element.role === "AXPopUpButton" && observation.bundleId && SAFARI_BUNDLES.has(observation.bundleId)) {
            throw ctx.refuse("unsupported", "In Safari the driver may set a <select> through AppleScript JavaScript in the front document, a browser route outside this adapter.");
          }
          return await act(call, target, "set_value", { pid: target.pid, element_token: element.token, value: action.value });
        }
        case "type": {
          if (action.ref) {
            const element = elementFor(observation, opts.observationId, action.ref);
            return await act(call, target, "type_text", { pid: target.pid, element_token: element.token, text: action.text });
          }
          return await act(call, target, "type_text", { ...base, text: action.text });
        }
        case "key": {
          const { key, modifiers } = parseCombo(action.combo);
          if (!key) throw ctx.refuse("invalid-action", `No key in combo "${action.combo}".`);
          if (modifiers.length) return await act(call, target, "hotkey", { ...base, keys: [...modifiers, key] });
          return await act(call, target, "press_key", { ...base, key });
        }
        case "click": {
          if (!observation.hasScreenshot) {
            throw ctx.refuse("invalid-action", "click points are pixels in the observation's screenshot; observe with screenshot first.");
          }
          return await act(call, target, "click", {
            ...base,
            x: action.point.x,
            y: action.point.y,
            ...(action.button ? { button: action.button } : {}),
            ...(action.count ? { count: action.count } : {}),
          });
        }
        case "scroll": {
          const amount = Math.min(50, Math.max(1, Math.round(action.amount ?? 3)));
          if (action.ref) {
            const element = elementFor(observation, opts.observationId, action.ref);
            return await act(call, target, "scroll", { pid: target.pid, element_token: element.token, direction: action.direction, amount });
          }
          if (!action.point) throw ctx.refuse("invalid-action", "scroll needs ref or point.");
          if (!observation.hasScreenshot) {
            throw ctx.refuse("invalid-action", "scroll points are pixels in the observation's screenshot; observe with screenshot first.");
          }
          return await act(call, target, "scroll", { ...base, x: action.point.x, y: action.point.y, direction: action.direction, amount });
        }
        default:
          throw ctx.refuse("unsupported", `cua-driver adapter has no mapping for ${(action as { kind: string }).kind}.`);
      }
    },

    async dispose() {
      lifetime.abort();
      closeClient();
    },
  };
}
