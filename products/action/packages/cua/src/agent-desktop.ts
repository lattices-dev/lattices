import { chmodSync, constants, mkdtempSync, realpathSync } from "node:fs";
import { mkdir, open, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { runAgentDesktop, type AgentDesktopRunner } from "./agent-desktop-process.js";
import { agentDesktopPermissionContext, createAgentDesktopSetup } from "./agent-desktop-setup.js";
import type { Backend, BackendAxNode, BackendCall, BackendContext, BackendObservation, BackendRefusalCode, BackendTier } from "./types.js";

type Json = Record<string, any>;
type Window = { id: string; app_name: string; title: string; pid: number; process_instance: string; is_focused?: boolean; bounds?: BackendObservation["bounds"] };
type Kept = { observation: BackendObservation; refs: Map<string, { native: string; actions: string[] }>; identityUnproven: boolean };
const object = (value: unknown): value is Json => !!value && typeof value === "object" && !Array.isArray(value);
const frame = (value: unknown): value is NonNullable<BackendObservation["bounds"]> => object(value)
  && ["x", "y", "width", "height"].every((key) => typeof value[key] === "number" && Number.isFinite(value[key]))
  && value.width >= 0 && value.height >= 0;
const tiers = { press: "semantic", setValue: "semantic", type: "attention", key: "attention", scroll: "attention" } as const;

/** agent-desktop JSON 2.6, headless mode. No installation, focus takeover, or global-input fallback. */
export function createAgentDesktopBackend(ctx: BackendContext): Backend {
  const configuredCommand = ctx.options.command ?? "agent-desktop";
  if (typeof configuredCommand !== "string" || !configuredCommand || configuredCommand.includes("\0")) throw ctx.refuse("unavailable", "agent-desktop command must be a nonempty executable name or path.");
  const command: string = configuredCommand;
  if (ctx.options.args !== undefined) throw ctx.refuse("unavailable", "agent-desktop does not accept extra command arguments; select its executable with command.");
  const runner: AgentDesktopRunner = typeof ctx.options.__run === "function" ? ctx.options.__run as AgentDesktopRunner : runAgentDesktop;
  const home = mkdtempSync(join(realpathSync(tmpdir()), "action-agent-desktop-"));
  chmodSync(home, 0o700);
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("AGENT_DESKTOP_")));
  env.AGENT_DESKTOP_HOME = home;
  const lifetime = new AbortController();
  const known = new Map<string, Window>();
  const latest = new Map<string, Kept>();
  let sequence = 0;
  let tail: Promise<unknown> = Promise.resolve();
  const check = (call: BackendCall) => {
    if (lifetime.signal.aborted) throw ctx.refuse("unavailable", "agent-desktop backend is disposed.");
    if (call.signal.aborted || Date.now() >= call.deadline) throw ctx.refuse("unavailable", "agent-desktop call cancelled or expired before delivery.");
  };
  const serial = <T>(call: BackendCall, body: () => Promise<T>): Promise<T> => {
    const result = tail.then(() => { check(call); return body(); });
    tail = result.catch(() => {});
    return result;
  };
  const budget = (call: BackendCall) => String(Math.max(1, Math.min(30_000, Math.floor(call.deadline - Date.now()))));
  const idOf = (window: Window) => `${ctx.generation}:agent-desktop:${Buffer.from(JSON.stringify([window.id, window.pid, window.process_instance])).toString("base64url")}`;
  async function run(call: BackendCall, verb: string, args: string[] = [], stdin?: string): Promise<any> {
    check(call);
    const result = await runner({ command, args: [verb, ...args], env: { ...env }, stdin,
      signal: AbortSignal.any([call.signal, lifetime.signal]), deadline: call.deadline });
    // Once spawned, a late/cancelled result cannot promise non-delivery. It must also
    // never publish new refs after cancellation, even if a runner returns success.
    if (call.signal.aborted || lifetime.signal.aborted || Date.now() >= call.deadline) throw new Error("agent-desktop returned after cancellation or its deadline; delivery may be uncertain.");
    let reply: unknown;
    try { reply = JSON.parse(result.stdout); } catch { throw new Error("agent-desktop returned invalid JSON; delivery is unknown."); }
    if (!object(reply) || reply.version !== "2.6" || reply.command !== verb || typeof reply.ok !== "boolean") {
      throw new Error("agent-desktop returned an unsupported or mismatched envelope (requires JSON 2.6); delivery is unknown.");
    }
    if (!reply.ok) {
      const error = reply.error;
      if (!object(error) || typeof error.code !== "string" || !/^[A-Z_]{1,64}$/.test(error.code) || typeof error.message !== "string" || !object(error.disposition)) {
        throw new Error("agent-desktop returned an invalid error envelope; delivery is unknown.");
      }
      // Codes alone never prove that a mutation did not land. Do not echo native UI/text diagnostics.
      if (error.disposition.delivery === "not_delivered") {
        const code: BackendRefusalCode = /^(STALE_REF|SNAPSHOT_NOT_FOUND|AMBIGUOUS_TARGET)$/.test(error.code) ? "stale-ref"
          : /^(WINDOW_NOT_FOUND|APP_NOT_FOUND)$/.test(error.code) ? "unknown-target"
          : error.code === "INVALID_ARGS" ? "invalid-action"
          : /^(ACTION_NOT_SUPPORTED|PLATFORM_NOT_SUPPORTED|POLICY_DENIED)$/.test(error.code) ? "unsupported" : "unavailable";
        throw ctx.refuse(code, `agent-desktop refused ${verb} (${error.code}); nothing was delivered.`);
      }
      throw new Error(`agent-desktop ${verb} failed (${error.code}); delivery is uncertain. Observe before retrying.`);
    }
    if (result.exitCode !== 0 || !("data" in reply)) throw new Error("agent-desktop returned inconsistent success evidence; delivery is unknown.");
    return reply.data;
  }
  async function windows(call: BackendCall): Promise<Window[]> {
    const data = await run(call, "list-windows", ["--timeout-ms", budget(call)]);
    if (!Array.isArray(data) || data.some((w) => !object(w) || typeof w.id !== "string" || typeof w.app_name !== "string" || typeof w.title !== "string" || !Number.isSafeInteger(w.pid) || w.pid <= 0
      || (w.is_focused !== undefined && typeof w.is_focused !== "boolean"))) {
      throw new Error("agent-desktop returned invalid window identities.");
    }
    const usable = data.filter((w): w is Window => w.id.length > 0 && typeof w.process_instance === "string" && w.process_instance.length > 0);
    if (new Set(usable.map((w) => w.id)).size !== usable.length) throw new Error("agent-desktop returned ambiguous window identifiers.");
    return usable;
  }
  async function requireWindow(call: BackendCall, targetId: string): Promise<Window> {
    const expected = known.get(targetId);
    if (!expected) throw ctx.refuse("unknown-target", "List targets again; this target does not belong to this backend generation.");
    const live = (await windows(call)).find((w) => idOf(w) === targetId);
    if (!live) {
      latest.delete(targetId);
      throw ctx.refuse("unknown-target", "The selected window or process instance changed; list targets again.");
    }
    return live;
  }
  async function observe(call: BackendCall, targetId: string, screenshot: boolean): Promise<BackendObservation> {
    const window = await requireWindow(call, targetId);
    // Failed refreshes invalidate old observations too: a partially written native snapshot must not be reused.
    latest.delete(targetId);
    const data = await run(call, "snapshot", ["--window-id", window.id, "--include-bounds", "--max-depth", "20", "--timeout-ms", budget(call)]);
    if (!object(data) || !object(data.window) || data.window.id !== window.id || data.app !== window.app_name
      || typeof data.snapshot_id !== "string" || !/^[a-zA-Z0-9_-]{3,64}$/.test(data.snapshot_id)
      || typeof data.complete !== "boolean" || (data.identity_unproven !== undefined && typeof data.identity_unproven !== "boolean")
      || (data.truncated !== undefined && typeof data.truncated !== "boolean")
      || (data.nodes_observed !== undefined && (!Number.isSafeInteger(data.nodes_observed) || data.nodes_observed < 0))
      || !object(data.tree)) throw new Error("agent-desktop snapshot did not confirm the selected window or schema.");
    const observationId = `${ctx.generation}-agent-desktop-${++sequence}`;
    const ax: BackendAxNode[] = [];
    const refs = new Map<string, { native: string; actions: string[] }>();
    const nativeRefs = new Set<string>();
    const queue = [{ node: data.tree, depth: 0 }];
    for (let index = 0; index < queue.length; index++) {
      const { node, depth } = queue[index]!;
      if (index >= 12_000 || depth > 100 || !object(node) || typeof node.role !== "string"
        || (node.children !== undefined && !Array.isArray(node.children))
        || (node.subtree_truncated !== undefined && typeof node.subtree_truncated !== "boolean")
        || (node.available_actions !== undefined && (!Array.isArray(node.available_actions) || node.available_actions.some((a: unknown) => typeof a !== "string")))) {
        throw new Error("agent-desktop snapshot tree is malformed or exceeds limits.");
      }
      const ref = `${observationId}:${index}`;
      const actions: string[] = node.available_actions ?? [];
      if (node.ref_id !== undefined) {
        if (typeof node.ref_id !== "string" || !node.ref_id.startsWith(`@${data.snapshot_id}:`) || !/^@[a-zA-Z0-9_-]+:e[0-9]+$/.test(node.ref_id)
          || nativeRefs.has(node.ref_id)) throw new Error("agent-desktop returned an invalid or duplicate snapshot-qualified ref.");
        nativeRefs.add(node.ref_id);
        refs.set(ref, { native: node.ref_id, actions });
      }
      ax.push({ ref, depth, role: node.role, ...(typeof node.name === "string" ? { label: node.name } : {}),
        ...(typeof node.value === "string" ? { value: node.value } : {}), actions: [...actions], settable: actions.includes("SetValue"),
        ...(node.subtree_truncated !== undefined ? { subtreeTruncated: node.subtree_truncated } : {}),
        ...(frame(node.bounds) ? { frame: node.bounds } : {}) });
      for (const child of node.children ?? []) queue.push({ node: child, depth: depth + 1 });
    }
    let shot: BackendObservation["screenshot"];
    let scale: number | undefined;
    if (screenshot) {
      await requireWindow(call, targetId);
      await mkdir(ctx.shotsDir, { recursive: true });
      const path = resolve(ctx.shotsDir, `${observationId}.png`);
      const capture = await run(call, "screenshot", ["--window-id", window.id, path]);
      if (!object(capture) || capture.path !== path || capture.format !== "png"
        || !Number.isSafeInteger(capture.width) || capture.width <= 0 || !Number.isSafeInteger(capture.height) || capture.height <= 0
        || typeof capture.scale_factor !== "number" || !Number.isFinite(capture.scale_factor) || !(capture.scale_factor > 0)) throw new Error("agent-desktop returned an invalid window screenshot result.");
      const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
      try {
        const stat = await file.stat();
        if (!stat.isFile() || stat.size < 8 || stat.size > 32 * 1024 * 1024) throw new Error("agent-desktop screenshot is not a bounded regular PNG file.");
        const bytes = Buffer.alloc(8);
        const { bytesRead } = await file.read(bytes, 0, 8, 0);
        if (bytesRead !== 8 || !bytes.equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) throw new Error("agent-desktop did not write a PNG screenshot.");
      } finally { await file.close(); }
      shot = { path, width: capture.width, height: capture.height };
      scale = capture.scale_factor;
    }
    await requireWindow(call, targetId);
    check(call);
    const observation: BackendObservation = { observationId, targetId, at: Date.now(), ax, complete: data.complete,
      ...(data.truncated !== undefined ? { truncated: data.truncated } : {}),
      ...(data.nodes_observed !== undefined ? { nodesObserved: data.nodes_observed } : {}),
      ...(frame(window.bounds) ? { bounds: window.bounds } : {}), ...(shot ? { screenshot: shot, scale } : {}) };
    latest.set(targetId, { observation, refs, identityUnproven: data.identity_unproven === true });
    return observation;
  }
  const setup = createAgentDesktopSetup(ctx, lifetime.signal,
    (call) => serial(call, () => run(call, "permissions")),
    (call, args) => run(call, "permissions", args));
  return {
    schema: 1,
    capabilities: { surfaces: ["computer"], observe: { ax: true, screenshot: true }, actions: tiers },
    availability: (call) => serial(call, async () => {
      try {
        const status = await run(call, "status");
        if (!object(status) || typeof status.version !== "string" || !object(status.permissions)) throw new Error("agent-desktop status schema is invalid.");
        const granted = (field: string) => ["granted", "not_required"].includes(status.permissions[field]?.state);
        if (!granted("accessibility")) return { ready: false, version: status.version, reason: "agent-desktop needs Accessibility permission.",
          permissionContext: agentDesktopPermissionContext,
          needs: [{ kind: "permission" as const, permission: "accessibility" as const,
            detail: "agent-desktop Accessibility permission is missing or unknown for its launcher.", fix: "Run action setup agent-desktop from the launcher that will use this backend." }] };
        return { ready: true, version: status.version,
          ...(!granted("screen_recording") ? { reason: "Accessibility is ready. Optional window screenshots need Screen Recording permission." } : {}) };
      } catch { return { ready: false, reason: "agent-desktop is unavailable or incompatible; configure an operator-installed executable supporting JSON 2.6.",
        needs: [{ kind: "install" as const, detail: "Install agent-desktop separately, or set agent-desktop.command to its executable path.", fix: "Configure agent-desktop.command; this backend never installs or launches a permission guide automatically." }] }; }
    }),
    setupAvailability: setup.availability,
    setup: setup.setup,
    targets: (call) => serial(call, async () => {
      const listed = await windows(call);
      known.clear();
      for (const window of listed) known.set(idOf(window), window);
      for (const id of latest.keys()) if (!known.has(id)) latest.delete(id);
      return listed.map((w) => ({ targetId: idOf(w), app: w.app_name, title: w.title, pid: w.pid, focused: w.is_focused === true }));
    }),
    observe: (call, id, opts) => serial(call, () => observe(call, id, opts.screenshot === true)),
    act: (call, id, action, opts) => serial(call, async () => {
      if (action.kind === "click" || action.kind === "secondary") throw ctx.refuse("unsupported", "agent-desktop does not expose coordinate clicks or secondary actions through this adapter.");
      const tier = (tiers as Partial<Record<string, BackendTier>>)[action.kind];
      if (!tier) throw ctx.refuse("unsupported", "agent-desktop does not expose coordinate clicks or secondary actions through this adapter.");
      if (!opts.allowTiers.includes(tier)) throw ctx.refuse("tier-not-allowed", `agent-desktop ${action.kind} requires ${tier}. Nothing was sent.`);
      const kept = latest.get(id);
      if (!kept || kept.observation.observationId !== opts.observationId) throw ctx.refuse("stale-ref", "Observe this target again; only its latest observation can be acted on.");
      if (kept.identityUnproven) throw ctx.refuse("stale-ref", "The snapshot could not prove element identity; observe again before acting.");
      let verb: string;
      let args: string[];
      let stdin: string | undefined;
      if (action.kind === "key") {
        if (!action.combo || action.combo.startsWith("-") || action.combo.includes("\0")) throw ctx.refuse("invalid-action", "Invalid key combination.");
        verb = "press";
        const window = await requireWindow(call, id);
        if (window.is_focused !== true) throw ctx.refuse("unsupported", "Scoped keys require the selected window to be focused; no focus or global-key fallback is used.");
        args = [action.combo, "--window-id", window.id];
      } else {
        if (!("ref" in action) || !action.ref) throw ctx.refuse("unsupported", "agent-desktop type and scroll require a ref; global input is not supported.");
        const ref = kept.refs.get(action.ref);
        if (!ref) throw ctx.refuse("stale-ref", "This ref is not actionable in the selected target's latest observation.");
        const capability = { press: "Click", setValue: "SetValue", type: "TypeText", scroll: "Scroll" }[action.kind];
        if (!ref.actions.includes(capability!)) throw ctx.refuse("unsupported", `This ref does not advertise ${capability}.`);
        verb = { press: "click", setValue: "set-value", type: "type", scroll: "scroll" }[action.kind]!;
        args = [ref.native, "--timeout-ms", budget(call)];
        if (action.kind === "setValue" || action.kind === "type") {
          stdin = action.kind === "setValue" ? action.value : action.text;
          if (typeof stdin !== "string" || Buffer.byteLength(stdin) > (action.kind === "type" ? 10_000 : 128 * 1024)) throw ctx.refuse("invalid-action", "Text exceeds agent-desktop's UTF-8 input limit.");
          args.push("--stdin");
        } else if (action.kind === "scroll") {
          const amount = action.amount ?? 3;
          if (!["up", "down", "left", "right"].includes(action.direction) || !Number.isSafeInteger(amount) || amount < 1 || amount > 50) throw ctx.refuse("invalid-action", "Scroll needs a direction and an integer amount from 1 to 50.");
          args.push("--direction", action.direction, "--amount", String(amount));
        }
        await requireWindow(call, id);
      }
      // Invalidate before dispatch: even an uncertain result must require a new observation.
      latest.delete(id);
      const data = await run(call, verb, args, stdin);
      // The command envelope uses `press`; the scoped macOS key result uses `press_key`.
      const resultAction = verb === "press" ? "press_key" : verb;
      if (!object(data) || data.action !== resultAction || !object(data.disposition)
        || !["delivered_verified", "delivered_unverified", "not_delivered"].includes(data.disposition.delivery)
        || (data.steps !== undefined && (!Array.isArray(data.steps) || data.steps.some((s: unknown) => !object(s))))) {
        throw new Error("agent-desktop returned invalid action delivery evidence; observe before retrying.");
      }
      if (tier === "semantic" && data.steps?.some((s: Json) => s.mechanism === "physical_synthetic")) {
        throw new Error("agent-desktop reported physical delivery for a semantic request; delivery is uncertain.");
      }
      return { outcome: "dispatched", tierUsed: tier, mechanism: `agent-desktop headless ${verb}`,
        message: `Native delivery: ${data.disposition.delivery}. Observe to verify the application effect.` };
    }),
    async dispose() {
      lifetime.abort();
      await setup.settle();
      await tail;
      known.clear(); latest.clear();
      await rm(home, { recursive: true, force: true });
    },
  };
}
