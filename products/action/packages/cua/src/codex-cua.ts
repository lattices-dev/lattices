/**
 * Action computer backend for Codex's `cua_repl` (the ChatGPT.app
 * "unified-computer-use" plugin). Ported from the arts-mini Scout adapter
 * (~/.openscout/computer-use/codex-cua.ts, 2026-10-03), with setup diagnostics
 * and bounded permission-readiness checks.
 *
 * Driver: the newest ~/.codex/plugins/cache/openai-bundled/unified-computer-use/<version>/.mcp.json,
 * server `cua_repl`. command/args/env are read from that file at start;
 * CUA_REPL_ENABLED_SURFACES is forced to "computer" (never browser).
 *
 * Every macOS Sky call (getApp, getAXState, click, ...) first asks the MCP
 * client "Allow Computer Use to use <app>?" through a form elicitation. The
 * backend answers those from the operator's allow list in
 * ~/Library/Application Support/Action/backends.json:
 *
 *   { "codex-cua": { "apps": ["com.apple.calculator"] } }
 *
 * Only `computer-use` app approvals whose app (bundle id) is in apps are
 * accepted, for this session only (never "always", so nothing is written to
 * Codex's persisted state). Every other elicitation is declined. With an empty
 * allow list the backend reports not ready. Targets are limited to running
 * apps on the allow list, so other apps are never listed or observed.
 *
 * Tiers, from probing cua_repl 26.930.31730 against Calculator with a
 * listen-only CGEventTap at HID, session and annotated-session level, and the
 * frontmost app sampled every 20 ms:
 *
 * - press     → app.performSecondaryAction(index, "Press"). No CGEvent seen at
 *   any tap, Calculator stayed in the background → semantic. (app.click(index)
 *   is NOT used: it synthesizes leftMouseDown/Up posted to the app's pid.)
 * - setValue  → app.setValue(index, value). The success path was never
 *   observed (Calculator has no settable element) → attention until verified.
 * - type / key / click / scroll → events posted to the pid → attention.
 * - secondary → app.performSecondaryAction(index, name): "Press" and "Raise"
 *   were verified not to activate the app → semantic for those, attention otherwise.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { homedir } from "node:os";
import { recordSetupStep, setupCall } from "./setup.js";
import type {
  BackendAction as Action,
  BackendAxNode as AxNode,
  BackendCall as Call,
  BackendContext as Ctx,
  BackendObservation as Observation,
  BackendTier as Tier,
  Backend,
  BackendAvailability,
  BackendNeed,
  BackendSetupStep,
  McpClient,
} from "./types.js";

type CuaClient = McpClient;

const PLUGIN_GLOB = "~/.codex/plugins/cache/openai-bundled/unified-computer-use/*";
const SENTINEL = "@@ACTION@@";
const KEEP_OBSERVATIONS = 8;
const MAX_NODES = 800;
const MAX_VALUE_CHARS = 200;
const VERIFIED_SEMANTIC_SECONDARY = new Set(["press", "raise"]);

/** cua's role descriptions → AX roles, longest first so "close button" wins over "button". */
const ROLES: Array<[string, string]> = ([
  ["standard window", "AXWindow"], ["window", "AXWindow"], ["dialog", "AXWindow"], ["sheet", "AXSheet"],
  ["close button", "AXButton"], ["zoom button", "AXButton"], ["minimize button", "AXButton"], ["full screen button", "AXButton"],
  ["pop up button", "AXPopUpButton"], ["menu button", "AXMenuButton"], ["radio button", "AXRadioButton"], ["toggle button", "AXCheckBox"],
  ["button", "AXButton"], ["checkbox", "AXCheckBox"], ["check box", "AXCheckBox"], ["switch", "AXCheckBox"],
  ["text field", "AXTextField"], ["search text field", "AXTextField"], ["secure text field", "AXTextField"], ["text entry area", "AXTextArea"],
  ["text area", "AXTextArea"], ["text", "AXStaticText"], ["static text", "AXStaticText"], ["heading", "AXHeading"],
  ["scroll area", "AXScrollArea"], ["scroll bar", "AXScrollBar"], ["split group", "AXSplitGroup"], ["splitter", "AXSplitter"],
  ["container", "AXGroup"], ["group", "AXGroup"], ["toolbar", "AXToolbar"], ["tab group", "AXTabGroup"], ["tab", "AXRadioButton"],
  ["menu bar item", "AXMenuBarItem"], ["menu bar", "AXMenuBar"], ["menu item", "AXMenuItem"], ["menu", "AXMenu"],
  ["combo box", "AXComboBox"], ["slider", "AXSlider"], ["stepper", "AXIncrementor"], ["incrementor", "AXIncrementor"],
  ["progress indicator", "AXProgressIndicator"], ["busy indicator", "AXBusyIndicator"], ["image", "AXImage"], ["link", "AXLink"],
  ["table", "AXTable"], ["outline", "AXOutline"], ["list", "AXList"], ["row", "AXRow"], ["cell", "AXCell"], ["column", "AXColumn"],
  ["collection", "AXList"], ["web area", "AXWebArea"], ["disclosure triangle", "AXDisclosureTriangle"], ["color well", "AXColorWell"],
  ["date field", "AXDateField"], ["level indicator", "AXLevelIndicator"], ["browser", "AXBrowser"], ["popover", "AXPopover"],
] as Array<[string, string]>).sort((a, b) => b[0].length - a[0].length);

function parseHead(head: string): { role: string; title?: string } {
  const lower = head.toLowerCase();
  for (const [name, role] of ROLES) {
    if (lower === name || lower.startsWith(`${name} `)) {
      const title = head.slice(name.length).trim();
      return title ? { role, title } : { role };
    }
  }
  // cua omits the role for some elements (menu bar items print only a title).
  return head ? { role: "AXUnknown", title: head } : { role: "AXUnknown" };
}

type ParsedNode = { index: number; depth: number; role: string; label?: string; value?: string; actions?: string[] };

/** Parses cua's formatted AX text: "<tabs><index> <role> [title], Key: value, ...". */
function parseAxText(text: string): ParsedNode[] {
  const nodes: ParsedNode[] = [];
  for (const line of text.split("\n")) {
    const match = /^(\t*)(\d+) (.*)$/.exec(line);
    if (!match) {
      // A continuation of a multi-line value belongs to the previous node.
      const last = nodes.at(-1);
      if (last && line.trim() && !/^Window: /.test(line)) last.value = `${last.value ?? ""}\n${line}`.slice(0, MAX_VALUE_CHARS);
      continue;
    }
    const [, tabs, index, rest] = match;
    const parts = rest!.split(/, (?=[A-Z][A-Za-z ]{0,30}: )/);
    let head = parts.shift() ?? "";
    const fields: Record<string, string> = {};
    // The first field follows the role with a space, not a comma: "button Description: 1, ID: One".
    const inline = /(?:^|\s)((?:Description|Help|ID|Value|Title|Placeholder|URL|Secondary Actions): )/.exec(head);
    if (inline) {
      const start = inline.index + (inline[0].length - inline[1]!.length);
      parts.unshift(head.slice(start));
      head = head.slice(0, start).trim();
    }
    for (const part of parts) {
      const colon = part.indexOf(": ");
      fields[part.slice(0, colon)] = part.slice(colon + 2);
    }
    // State/type descriptors ("(selected, settable, boolean)") are not part of the label.
    head = head.replace(/\s*\((?:(?:disabled|selected|focused|expanded|collapsed|settable|boolean|string|number|integer|float|checked|unchecked|mixed)(?:,\s*)?)+\)\s*/g, " ").trim();
    const { role, title } = parseHead(head);
    const isText = role === "AXStaticText" || role === "AXTextField" || role === "AXTextArea";
    const value = fields.Value ?? (isText ? title : undefined);
    const label = fields.Description ?? (isText && !fields.Value ? undefined : title) ?? fields.Title ?? fields.Help ?? fields.ID;
    const actions = fields["Secondary Actions"]?.split(", ").map((s) => s.trim()).filter(Boolean);
    nodes.push({
      index: Number(index),
      depth: tabs!.length,
      role,
      ...(label ? { label } : {}),
      ...(value ? { value: value.slice(0, MAX_VALUE_CHARS) } : {}),
      ...(actions?.length ? { actions } : {}),
    });
  }
  return nodes;
}

/** xdotool-style combo from the contract → cua pressKey syntax. */
function comboToCua(combo: string): string {
  return combo.split("+").map((part) => part.trim()).filter(Boolean).map((part) => ({
    cmd: "super", command: "super", meta: "super", opt: "alt", option: "alt", ctrl: "ctrl", control: "ctrl",
  })[part.toLowerCase()] ?? part).join("+");
}

type Kept = { bundleId: string; nodes: Map<string, ParsedNode> };

export function createCodexCuaBackend(ctx: Ctx): Backend {
  const apps = (Array.isArray(ctx.options.apps) ? ctx.options.apps : []).map((app) => String(app).trim().toLowerCase()).filter(Boolean);
  const allowed = (id: string | undefined, name?: string) =>
    Boolean(id && apps.includes(id.toLowerCase())) || Boolean(name && apps.includes(name.toLowerCase()));

  let client: Promise<CuaClient> | null = null;
  const discarded = new WeakSet<Promise<CuaClient>>();
  const lifetime = new AbortController();
  let version: string | undefined;
  let nextObservation = 1;
  const kept = new Map<string, Kept>();
  /** The observation whose element indexes are cua's latest state, per app. */
  const latest = new Map<string, string>();

  const fix = "action setup codex-cua";
  const installNeed = (detail: string): BackendNeed => ({
    kind: "install", detail: `${detail} Install or update the Computer Use (unified-computer-use) plugin in the ChatGPT desktop app; it must provide mcpServers.cua_repl and the js tool.`, fix,
  });
  const configNeed = (): BackendNeed => ({
    kind: "config", fix,
    detail: `options.apps is empty: merge {"codex-cua":{"apps":["com.apple.calculator"]}} into ${ctx.configPath ?? process.env.ACTION_BACKENDS_CONFIG ?? join(process.env.ACTION_SUPPORT_DIRECTORY ?? join(homedir(), "Library/Application Support/Action"), "backends.json")}. Replace the example with the bundle IDs you approve, then restart this host.`,
  });

  function plugin() {
    const dir = ctx.newestDir(PLUGIN_GLOB);
    if (!dir) throw ctx.refuse("unavailable", `No Codex computer-use plugin under ${PLUGIN_GLOB}.`);
    const manifest = join(dir, ".mcp.json");
    if (!existsSync(manifest)) throw ctx.refuse("unavailable", `${manifest} is missing.`);
    const server = JSON.parse(readFileSync(manifest, "utf8"))?.mcpServers?.cua_repl;
    if (!server?.command) throw ctx.refuse("unavailable", `${manifest} has no mcpServers.cua_repl.command.`);
    return { dir, server };
  }

  function checkCall(call: Call): void {
    call.signal.throwIfAborted();
    lifetime.signal.throwIfAborted();
    if (Date.now() >= call.deadline) throw new Error("codex-cua call deadline expired.");
  }

  /** Also bounds injected clients that ignore the transport's cancellation options. */
  async function bounded<T>(call: Call, pending: Promise<T>, stop?: () => void): Promise<T> {
    const signal = AbortSignal.any([call.signal, lifetime.signal]);
    let timer: ReturnType<typeof setTimeout> | undefined;
    let onAbort = () => {};
    const cancelled = new Promise<never>((_, reject) => {
      onAbort = () => {
        stop?.();
        reject(signal.reason instanceof Error ? signal.reason : new Error("codex-cua call cancelled."));
      };
      signal.addEventListener("abort", onAbort, { once: true });
      timer = setTimeout(() => {
        stop?.();
        reject(new Error("codex-cua call deadline expired."));
      }, Math.max(0, call.deadline - Date.now()));
      if (signal.aborted) onAbort();
    });
    try {
      const result = await Promise.race([pending, cancelled]);
      checkCall(call);
      return result;
    } finally {
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
    }
  }

  function discard(connection: Promise<CuaClient>): void {
    if (client === connection) client = null;
    if (discarded.has(connection)) return;
    discarded.add(connection);
    // If negotiation finishes after cancellation, close that client rather than
    // putting it back in the cache or leaving an orphaned driver behind.
    void connection.then((connected) => connected.close(), () => {});
  }

  function driver(call: Call): Promise<CuaClient> {
    checkCall(call);
    if (client) return client;
    const connection = (async () => {
      const { dir, server } = plugin();
      version = basename(dir);
      const env: Record<string, string> = { ...(server.env ?? {}), CUA_REPL_ENABLED_SURFACES: "computer" };
      return await ctx.stdioMcp({
        command: String(server.command),
        args: (server.args ?? []).map(String),
        env,
        timeoutMs: Math.max(1, call.deadline - Date.now()),
        signal: AbortSignal.any([call.signal, lifetime.signal]),
        onElicitation: (params) => {
          // Only Computer Use's per-app approval, only for allow-listed apps.
          // "session" only: never persist an "always" approval into Codex's own state.
          const meta = params?._meta ?? {};
          const app = meta?.tool_params?.app;
          const ok = meta?.connector_id === "computer-use" && typeof app === "string" && allowed(app);
          return ok ? { content: {}, _meta: { persist: "session" } } : null;
        },
      });
    })().catch((error) => {
      if (client === connection) client = null;
      throw error;
    });
    client = connection;
    return connection;
  }

  async function connect(call: Call): Promise<CuaClient> {
    const connection = driver(call);
    return await bounded(call, connection, () => discard(connection));
  }

  /** Runs `body` (the inside of an async function) in the REPL and returns its JSON result. */
  async function run<T>(call: Call, body: string, args: unknown = null): Promise<T> {
    const c = await connect(call);
    const connection = client;
    const timeoutMs = Math.max(1, call.deadline - Date.now());
    const code = `nodeRepl.write(${JSON.stringify(SENTINEL)} + JSON.stringify(await (async (args) => {
  globalThis.__action ??= { apps: {} };
  try { ${body} } catch (error) { return { __error: String(error?.message ?? error) }; }
})(${JSON.stringify(args)})));`;
    const result = await bounded(call,
      c.callTool("js", { code, timeout_ms: timeoutMs }, { timeoutMs, signal: call.signal }),
      () => { if (connection) discard(connection); });
    const text = (result?.content ?? []).filter((p) => p.type === "text").map((p) => p.text ?? "").join("\n");
    const at = text.lastIndexOf(SENTINEL);
    if (at < 0) throw new Error(`cua_repl returned no result${result?.isError ? `: ${text.slice(0, 400)}` : ""}`);
    const end = text.indexOf("\n", at);
    const parsed = JSON.parse(text.slice(at + SENTINEL.length, end < 0 ? undefined : end));
    if (parsed && typeof parsed === "object" && "__error" in parsed) throw Object.assign(new Error(parsed.__error), { driver: true });
    return parsed as T;
  }

  const bundleOf = (targetId: string): string => {
    const [generation, bundleId] = targetId.split(/:(.*)/s);
    if (generation !== ctx.generation || !bundleId) throw ctx.refuse("unknown-target", `${targetId} is not a target of this adapter generation.`);
    if (!allowed(bundleId)) throw ctx.refuse("unknown-target", `${bundleId} is not in this adapter's options.apps.`);
    return bundleId;
  };

  /** Binds the app in the REPL (getApp alone, as cua expects for a first use). */
  const BIND = `const a = (globalThis.__action.apps[args.bundleId] ??= await cua.getApp(args.bundleId));`;

  function keep(bundleId: string, targetId: string, text: string, shot?: { b64: string; mime: string } | null): Observation {
    const observationId = `${ctx.generation}-${nextObservation++}`;
    const parsed = parseAxText(text).slice(0, MAX_NODES);
    const byRef = new Map<string, ParsedNode>();
    const ax: AxNode[] = parsed.map((node) => {
      const ref = `${observationId}.${node.index}`;
      byRef.set(ref, node);
      return {
        ref,
        depth: node.depth,
        role: node.role,
        ...(node.label ? { label: node.label } : {}),
        ...(node.value ? { value: node.value } : {}),
        ...(node.actions ? { actions: node.actions } : {}),
      };
    });
    kept.set(observationId, { bundleId, nodes: byRef });
    while (kept.size > KEEP_OBSERVATIONS) kept.delete(kept.keys().next().value!);
    latest.set(bundleId, observationId);
    let screenshot: Observation["screenshot"];
    if (shot?.b64) {
      const path = join(ctx.shotsDir, `${observationId}.${shot.mime === "image/png" ? "png" : "jpg"}`);
      writeFileSync(path, Buffer.from(shot.b64, "base64"));
      screenshot = { path };
    }
    return { observationId, targetId, at: Date.now(), ax, ...(screenshot ? { screenshot } : {}) };
  }

  /** Resolves a ref to cua's element index, refusing unless the observation is cua's latest for the app. */
  async function element(call: Call, observationId: string, ref: string, bundleId: string, targetId: string): Promise<ParsedNode> {
    const observation = kept.get(observationId);
    const node = observation?.bundleId === bundleId && ref.startsWith(`${observationId}.`) ? observation.nodes.get(ref) : undefined;
    if (!node || latest.get(bundleId) !== observationId) {
      const fresh = await observeAndKeep(call, bundleId, targetId, false);
      throw ctx.refuse("stale-ref", `${ref} is not an element of the latest observation of ${bundleId}. Act again from ${fresh.observationId}.`, fresh);
    }
    return node;
  }

  /**
   * Verifies, in the same REPL call as the action, that cua's index still names
   * the element that was observed, so an index cannot drift onto another element.
   */
  const VERIFY = `const s = await a.getAXState({ emit: false, disableDiffing: true });
      const line = s.split("\\n").find((l) => new RegExp("^\\\\t*" + args.index + " ").test(l));
      if (!line || line.replace(/^\\t*\\d+ /, "") !== args.expect) return { stale: true, text: s };`;

  const lines = new Map<string, Map<number, string>>();
  const lineFor = (observationId: string, node: ParsedNode) => lines.get(observationId)?.get(node.index);
  const keepLines = (observationId: string, text: string) => {
    const map = new Map<number, string>();
    for (const l of text.split("\n")) {
      const m = /^\t*(\d+) (.*)$/.exec(l);
      if (m) map.set(Number(m[1]), m[2]!);
    }
    lines.set(observationId, map);
    while (lines.size > KEEP_OBSERVATIONS) lines.delete(lines.keys().next().value!);
  };

  // Wrap observeApp/keep so raw lines are kept for VERIFY.
  const observeAndKeep = async (call: Call, bundleId: string, targetId: string, screenshot: boolean) => {
    const result = await run<{ text: string; shot?: { b64: string; mime: string } | null }>(call, `${BIND}
      if (!args.screenshot) return { text: await a.getAXState({ emit: false, disableDiffing: true }) };
      const r = await a.getAXStateAndScreenshot({ emit: false, disableDiffing: true });
      const bytes = r.screenshot ? Buffer.from(r.screenshot) : null;
      const mime = bytes && bytes[0] === 0x89 ? "image/png" : "image/jpeg";
      return { text: r.state, shot: bytes ? { b64: bytes.toString("base64"), mime } : null };`, { bundleId, screenshot });
    const observation = keep(bundleId, targetId, result.text, result.shot);
    keepLines(observation.observationId, result.text);
    return observation;
  };

  /** Runs an indexed action after VERIFY; returns the post-action observation. */
  async function indexed(call: Call, bundleId: string, targetId: string, observationId: string, node: ParsedNode, actionJs: string, extra: Record<string, unknown>) {
    const expect = lineFor(observationId, node);
    const result = await run<{ stale?: boolean; text?: string; error?: string; after?: string }>(call, `${BIND}
      ${VERIFY}
      try { ${actionJs} } catch (error) { return { error: String(error?.message ?? error) }; }
      return { after: await a.getAXState({ emit: false, disableDiffing: true }) };`, { bundleId, index: node.index, expect, ...extra });
    if (result.stale) {
      const fresh = keep(bundleId, targetId, result.text!);
      keepLines(fresh.observationId, result.text!);
      throw ctx.refuse("stale-ref", `The element moved since ${observationId}; nothing was done. Act again from ${fresh.observationId}.`, fresh);
    }
    if (result.error) return { error: result.error } as const;
    const after = keep(bundleId, targetId, result.after!);
    keepLines(after.observationId, result.after!);
    return { observation: after } as const;
  }

  /** Runs a non-indexed action; returns the post-action observation. */
  async function plain(call: Call, bundleId: string, targetId: string, actionJs: string, extra: Record<string, unknown>) {
    const result = await run<{ error?: string; after?: string }>(call, `${BIND}
      try { ${actionJs} } catch (error) { return { error: String(error?.message ?? error) }; }
      return { after: await a.getAXState({ emit: false, disableDiffing: true }) };`, { bundleId, ...extra });
    if (result.error) return { error: result.error } as const;
    const after = keep(bundleId, targetId, result.after!);
    keepLines(after.observationId, result.after!);
    return { observation: after } as const;
  }

  // Errors the service raises while validating, before it sends anything.
  const PRECHECK = /is not a valid secondary action|not settable|does not support a settable|Invalid scroll direction|Missing scroll|out of range|No element|not found/i;

  async function availability(call: Call): Promise<BackendAvailability> {
    checkCall(call);
    const needs: BackendNeed[] = [];
    if (!apps.length) needs.push(configNeed());
    try { plugin(); }
    catch (error) { needs.push(installNeed(error instanceof Error ? error.message : String(error))); }
    if (needs.length) return { ready: false, reason: needs.map((need) => need.detail).join("\n"), needs };
    try {
      const c = await connect(call);
      const connection = client;
      const tools = await bounded(call, c.listTools({ signal: call.signal, timeoutMs: Math.max(1, call.deadline - Date.now()) }),
        () => { if (connection) discard(connection); });
      if (!tools.some((tool) => tool.name === "js")) {
        const need = installNeed("The configured cua_repl server does not expose js.");
        return { ready: false, reason: need.detail, needs: [need] };
      }
      const count = await run<unknown>(call, `return (await cua.listApps({ emit: false })).length;`);
      if (typeof count !== "number" || !Number.isSafeInteger(count) || count < 0) {
        throw new Error("cua_repl readiness check returned an invalid app count.");
      }
      checkCall(call);
      return { ready: true, ...(version ? { version: `cua_repl ${version} (${count} apps)` } : {}) };
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      const missing = /ENOENT|EACCES|not found|unknown tool|no.*cua_repl|missing/i.test(reason);
      return { ready: false, reason, ...(missing ? { needs: [installNeed(reason)] } : {}) };
    }
  }

  return {
    schema: 1 as const,
    capabilities: {
      surfaces: ["computer"] as ["computer"],
      observe: { ax: true, screenshot: true },
      actions: {
        press: "semantic",
        setValue: "attention",
        type: "attention",
        key: "attention",
        click: "attention",
        scroll: "attention",
        secondary: "attention",
      } as Record<string, Tier>,
    },

    availability,

    async setup(input) {
      const call = setupCall(input);
      const steps: BackendSetupStep[] = [];
      const step = (value: BackendSetupStep) => recordSetupStep(ctx, call, steps, value);
      step({ step: "macOS permissions", status: "skipped", detail: "codex-cua can verify its plugin and apps allow list, but cannot request or grant macOS permissions. Complete any Computer Use permission onboarding in the ChatGPT desktop app." });
      try {
        const status = await availability(call);
        if (status.needs?.length) {
          for (const need of status.needs) step({ step: need.kind === "install" ? "Install Computer Use" : "Configure apps allow list", status: "waiting-on-user", detail: need.detail });
        } else {
          step({ step: "Verify Computer Use", status: status.ready ? "done" : "failed", detail: status.reason ?? "Plugin, cua_repl, and apps allow list are ready." });
        }
        return { ready: status.ready, steps, ...(status.needs ? { needs: status.needs } : {}) };
      } catch (error) {
        step({ step: "Verify Computer Use", status: "failed", detail: error instanceof Error ? error.message : String(error) });
        return { ready: false, steps };
      }
    },

    async targets(call: Call) {
      const listed = await run<Array<{ id: string; displayName?: string; isRunning?: boolean }>>(call,
        `return (await cua.listApps({ emit: false })).filter((x) => x.isRunning).map((x) => ({ id: x.id, displayName: x.displayName, isRunning: x.isRunning }));`);
      // Only allow-listed apps leave this process: others are not even named.
      return listed.filter((app) => allowed(app.id, app.displayName)).map((app) => ({
        targetId: `${ctx.generation}:${app.id}`,
        app: app.displayName ?? app.id,
        bundleId: app.id,
      }));
    },

    async observe(call: Call, targetId: string, opts: { screenshot?: boolean }) {
      return await observeAndKeep(call, bundleOf(targetId), targetId, opts.screenshot === true);
    },

    async act(call: Call, targetId: string, action: Action, opts: { observationId: string; allowTiers: Tier[] }) {
      const bundleId = bundleOf(targetId);
      // A validation error the service raises before sending anything is a refusal;
      // anything else may have acted, so it is thrown and the owner reports "unknown".
      const fail = (error: string, _tier: Tier): never => {
        if (PRECHECK.test(error)) throw ctx.refuse("invalid-action", `cua_repl refused before acting: ${error}`);
        throw new Error(`cua_repl: ${error.slice(0, 500)}`);
      };
      switch (action.kind) {
        case "press": {
          const node = await element(call, opts.observationId, action.ref, bundleId, targetId);
          const r = await indexed(call, bundleId, targetId, opts.observationId, node, `await a.performSecondaryAction(args.index, "Press");`, {});
          if ("error" in r) return fail(r.error!, "semantic");
          return { outcome: "dispatched" as const, tierUsed: "semantic" as const, mechanism: "ax:AXPress (cua performSecondaryAction \"Press\")", observation: r.observation };
        }
        case "setValue": {
          const node = await element(call, opts.observationId, action.ref, bundleId, targetId);
          const r = await indexed(call, bundleId, targetId, opts.observationId, node, `await a.setValue(args.index, args.value);`, { value: action.value });
          if ("error" in r) return fail(r.error!, "attention");
          return { outcome: "dispatched" as const, tierUsed: "attention" as const, mechanism: "cua setValue (driver checks AX settable and sets AXValue; success path unverified)", observation: r.observation };
        }
        case "type": {
          if (action.ref) throw ctx.refuse("unsupported", "cua_repl types into the app's current focus only; use setValue on the ref, or type without a ref.");
          const r = await plain(call, bundleId, targetId, `await a.typeText(args.text);`, { text: action.text });
          if ("error" in r) return fail(r.error!, "attention");
          return { outcome: "dispatched" as const, tierUsed: "attention" as const, mechanism: "cgevent:keyboard posted to the app pid", observation: r.observation };
        }
        case "key": {
          const r = await plain(call, bundleId, targetId, `await a.pressKey(args.key);`, { key: comboToCua(action.combo) });
          if ("error" in r) return fail(r.error!, "attention");
          return { outcome: "dispatched" as const, tierUsed: "attention" as const, mechanism: "cgevent:keyboard posted to the app pid", observation: r.observation };
        }
        case "click": {
          const r = await plain(call, bundleId, targetId, `await a.click([args.x, args.y], { ...(args.button ? { mouseButton: args.button } : {}), ...(args.count ? { clickCount: args.count } : {}) });`,
            { x: action.point.x, y: action.point.y, button: action.button, count: action.count });
          if ("error" in r) return fail(r.error!, "attention");
          return { outcome: "dispatched" as const, tierUsed: "attention" as const, mechanism: "cgevent:pointer posted to the app pid", observation: r.observation };
        }
        case "scroll": {
          const pages = action.amount ?? 1;
          if (action.ref) {
            const node = await element(call, opts.observationId, action.ref, bundleId, targetId);
            const r = await indexed(call, bundleId, targetId, opts.observationId, node, `await a.scroll(args.index, args.direction, args.pages);`, { direction: action.direction, pages });
            if ("error" in r) return fail(r.error!, "attention");
            return { outcome: "dispatched" as const, tierUsed: "attention" as const, mechanism: "cgevent:scrollWheel posted to the app pid", observation: r.observation };
          }
          if (!action.point) throw ctx.refuse("invalid-action", "scroll needs ref or point.");
          const r = await plain(call, bundleId, targetId, `await a.scroll([args.x, args.y], args.direction, args.pages);`, { x: action.point.x, y: action.point.y, direction: action.direction, pages });
          if ("error" in r) return fail(r.error!, "attention");
          return { outcome: "dispatched" as const, tierUsed: "attention" as const, mechanism: "cgevent:scrollWheel posted to the app pid", observation: r.observation };
        }
        case "secondary": {
          const node = await element(call, opts.observationId, action.ref, bundleId, targetId);
          const tierUsed: Tier = VERIFIED_SEMANTIC_SECONDARY.has(String(action.name).trim().toLowerCase()) ? "semantic" : "attention";
          const r = await indexed(call, bundleId, targetId, opts.observationId, node, `await a.performSecondaryAction(args.index, args.name);`, { name: action.name });
          if ("error" in r) return fail(r.error!, tierUsed);
          return { outcome: "dispatched" as const, tierUsed, mechanism: `ax:${action.name} (cua performSecondaryAction)`, observation: r.observation };
        }
        default:
          throw ctx.refuse("unsupported", `codex-cua has no mapping for ${(action as { kind: string }).kind}.`);
      }
    },

    async dispose() {
      const connection = client;
      client = null;
      lifetime.abort();
      if (connection) discard(connection);
    },
  };
}
