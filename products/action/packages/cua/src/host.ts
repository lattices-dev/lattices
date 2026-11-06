import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createActionCuaBackend } from "./action-cua.js";
import { createCodexCuaBackend } from "./codex-cua.js";
import { stdioMcp } from "./stdio-mcp.js";
import { createTrycuaCuaBackend } from "./trycua-cua.js";
import { SETUP_TIMEOUT_MS } from "./setup.js";
import {
  BackendRefusal,
  type Backend,
  type BackendAction,
  type BackendActResult,
  type BackendAvailability,
  type BackendCall,
  type BackendContext,
  type BackendFactory,
  type BackendObservation,
  type BackendTarget,
  type BackendTier,
  type BackendSetupResult,
  type BackendSetupOptions,
} from "./types.js";

/** Backends Action can drive through. Each is chosen explicitly: there is no fallback between them. */
export const computerBackends: Record<string, { factory: BackendFactory; summary: string }> = {
  "action-cua": {
    factory: createActionCuaBackend,
    summary: "Action's own native host (Action.app): AX press/set-value by label, HID input for attention.",
  },
  "codex-cua": {
    factory: createCodexCuaBackend,
    summary: "Codex Computer Use (cua_repl from the ChatGPT app's unified-computer-use plugin). Needs an apps allow list.",
  },
  "trycua-cua": {
    factory: createTrycuaCuaBackend,
    summary: "trycua Cua Driver (cua-driver mcp, proxied to CuaDriver.app). Operator-installed.",
  },
};

export const backendTiers: BackendTier[] = ["observe", "semantic", "target-focus", "attention"];
/** What a backend act may use unless the caller allows more. Attention takes the operator's input. */
export const defaultAllowTiers: BackendTier[] = ["observe", "semantic"];

const supportDir = () => resolve(process.env.ACTION_SUPPORT_DIRECTORY ?? join(homedir(), "Library/Application Support/Action"));
export const backendsConfigPath = () => resolve(process.env.ACTION_BACKENDS_CONFIG ?? join(supportDir(), "backends.json"));

function expandHome(path: string): string {
  return path === "~" ? homedir() : path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

/** The newest directory matching `parent/*`, by mtime. Only a trailing `*` is a wildcard. */
export function newestDir(pattern: string): string | null {
  const expanded = expandHome(pattern);
  if (!expanded.endsWith("/*")) return existsSync(expanded) && statSync(expanded).isDirectory() ? expanded : null;
  const parent = dirname(expanded);
  if (!existsSync(parent)) return null;
  let best: { path: string; mtime: number } | null = null;
  for (const name of readdirSync(parent)) {
    if (name.startsWith(".")) continue;
    const path = join(parent, name);
    const stat = statSync(path, { throwIfNoEntry: false });
    if (!stat?.isDirectory()) continue;
    if (!best || stat.mtimeMs > best.mtime) best = { path, mtime: stat.mtimeMs };
  }
  return best?.path ?? null;
}

function readConfig(path: string): Record<string, Record<string, unknown>> {
  if (!existsSync(path)) return {};
  const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error(`${path} must hold a JSON object keyed by backend id.`);
  return parsed as Record<string, Record<string, unknown>>;
}

const KINDS = new Set(["press", "setValue", "type", "key", "click", "scroll", "secondary"]);
const DIRECTIONS = new Set(["up", "down", "left", "right"]);

/** Checks an action's shape before any backend sees it, so a malformed act is a refusal, not an unknown outcome. */
export function parseBackendAction(value: unknown): BackendAction {
  const bad = (message: string) => new BackendRefusal("invalid-action", message);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw bad("action must be an object with a kind.");
  const a = value as Record<string, unknown>;
  const kind = String(a.kind ?? "");
  if (!KINDS.has(kind)) throw bad(`action.kind must be one of ${[...KINDS].join(", ")}.`);
  const str = (key: string, optional = false) => {
    const v = a[key];
    if (v === undefined && optional) return undefined;
    if (typeof v !== "string" || (!optional && !v)) throw bad(`${kind} needs ${key} (a string).`);
    return v;
  };
  const point = (optional: boolean) => {
    const p = a.point as { x?: unknown; y?: unknown } | undefined;
    if (p === undefined && optional) return undefined;
    if (!p || !Number.isFinite(Number(p.x)) || !Number.isFinite(Number(p.y))) throw bad(`${kind} needs point {x, y}.`);
    return { x: Number(p.x), y: Number(p.y) };
  };
  switch (kind) {
    case "press": return { kind, ref: str("ref")! };
    case "setValue": return { kind, ref: str("ref")!, value: str("value", true) ?? "" };
    case "type": {
      const ref = str("ref", true);
      return { kind, text: str("text")!, ...(ref ? { ref } : {}) };
    }
    case "key": return { kind, combo: str("combo")! };
    case "click": {
      const button = a.button === "right" ? "right" : a.button === undefined || a.button === "left" ? a.button : undefined;
      if (a.button !== undefined && button === undefined) throw bad("click button is left or right.");
      const count = a.count === undefined ? undefined : Number(a.count);
      if (count !== undefined && (!Number.isInteger(count) || count < 1 || count > 3)) throw bad("click count is 1, 2 or 3.");
      return { kind, point: point(false)!, ...(button ? { button } : {}), ...(count ? { count } : {}) };
    }
    case "scroll": {
      const direction = String(a.direction ?? "");
      if (!DIRECTIONS.has(direction)) throw bad("scroll direction is up, down, left or right.");
      const ref = str("ref", true);
      const p = point(true);
      if (!ref && !p) throw bad("scroll needs ref or point.");
      const amount = a.amount === undefined ? undefined : Number(a.amount);
      if (amount !== undefined && !(amount > 0)) throw bad("scroll amount must be positive.");
      return { kind, direction: direction as "up", ...(ref ? { ref } : {}), ...(p ? { point: p } : {}), ...(amount ? { amount } : {}) };
    }
    default: return { kind: "secondary", ref: str("ref")!, name: str("name")! };
  }
}

export function parseAllowTiers(value: unknown): BackendTier[] {
  if (value === undefined) return [...defaultAllowTiers];
  if (!Array.isArray(value) || value.some((tier) => !backendTiers.includes(tier as BackendTier))) {
    throw new BackendRefusal("invalid-action", `allowTiers is a list of ${backendTiers.join(", ")}.`);
  }
  return [...new Set(["observe", ...value] as BackendTier[])];
}

export type BackendHostOptions = {
  configPath?: string;
  shotsDir?: string;
  log?: (...args: unknown[]) => void;
  /** Swapped in by tests. */
  backends?: Record<string, { factory: BackendFactory; summary: string }>;
  stdioMcp?: BackendContext["stdioMcp"];
};

export type BackendCallInput = { caller?: string; sessionId?: string; timeoutMs?: number; signal?: AbortSignal; onSetupStep?: BackendCall["onSetupStep"] };

/**
 * Owns the live backend instances of one Action MCP process. Instances start
 * lazily on first use and share one generation, so targets and refs from an
 * earlier process are refused instead of acting on whatever now has that id.
 */
export class BackendHost {
  readonly generation = randomUUID().slice(0, 8);
  private live = new Map<string, Backend>();
  private registry: Record<string, { factory: BackendFactory; summary: string }>;
  private log: (...args: unknown[]) => void;

  constructor(private options: BackendHostOptions = {}) {
    this.registry = options.backends ?? computerBackends;
    this.log = options.log ?? ((...args) => process.stderr.write(`[action backend] ${args.map(String).join(" ")}\n`));
  }

  ids(): string[] {
    return Object.keys(this.registry);
  }

  summary(id: string): string | undefined {
    return this.registry[id]?.summary;
  }

  get(id: string): Backend {
    const existing = this.live.get(id);
    if (existing) return existing;
    const entry = this.registry[id];
    if (!entry) throw new BackendRefusal("unsupported", `Unknown backend ${JSON.stringify(id)}. Backends: ${this.ids().join(", ")}.`);
    const configPath = this.options.configPath ?? backendsConfigPath();
    const shotsDir = this.options.shotsDir ?? join(supportDir(), "runtime/backends/shots", id);
    mkdirSync(shotsDir, { recursive: true });
    const log = (...args: unknown[]) => this.log(`${id}:`, ...args);
    const ctx: BackendContext = {
      generation: this.generation,
      options: readConfig(configPath)[id] ?? {},
      configPath,
      stdioMcp: this.options.stdioMcp ?? ((opts) => stdioMcp(opts, log)),
      newestDir,
      shotsDir,
      log,
      refuse: (code, message, observation) => new BackendRefusal(code, message, observation),
    };
    const backend = entry.factory(ctx);
    this.live.set(id, backend);
    return backend;
  }

  call(input: BackendCallInput = {}): BackendCall {
    const timeoutMs = input.timeoutMs ?? 30_000;
    const signal = input.signal ? AbortSignal.any([input.signal, AbortSignal.timeout(timeoutMs)]) : AbortSignal.timeout(timeoutMs);
    return {
      requestId: randomUUID(),
      caller: input.caller ?? "action",
      ...(input.sessionId ? { sessionId: input.sessionId } : {}),
      signal,
      deadline: Date.now() + timeoutMs,
      ...(input.onSetupStep ? { onSetupStep: input.onSetupStep } : {}),
    };
  }

  async availability(id: string, input?: BackendCallInput): Promise<BackendAvailability> {
    return await this.get(id).availability(this.call(input));
  }

  async setup(id: string, input: BackendCallInput = {}, opts: BackendSetupOptions = { interactive: true }): Promise<BackendSetupResult> {
    const backend = this.get(id);
    const call = this.call({ ...input, timeoutMs: input.timeoutMs ?? SETUP_TIMEOUT_MS });
    if (backend.setup) return await backend.setup(call, opts);
    const availability = await backend.availability(call);
    const step: BackendSetupResult["steps"][number] = {
      step: "Check availability", status: availability.ready ? "done" : "skipped",
      detail: availability.reason ?? "This backend has no setup procedure.",
    };
    if (call.onSetupStep) call.onSetupStep(step);
    else this.log(`${id}: [${step.status}] ${step.step}: ${step.detail}`);
    return { ...availability, steps: [step] };
  }

  async targets(id: string, input?: BackendCallInput): Promise<BackendTarget[]> {
    return await this.get(id).targets(this.call(input));
  }

  async observe(id: string, targetId: string, screenshot: boolean, input?: BackendCallInput): Promise<BackendObservation> {
    return await this.get(id).observe(this.call(input), targetId, { screenshot });
  }

  /** The tier the backend declares for this action; a refusal when the caller has not allowed it. */
  gate(id: string, action: BackendAction, allowTiers: BackendTier[]): BackendTier {
    const declared = this.get(id).capabilities.actions[action.kind];
    if (!declared) throw new BackendRefusal("unsupported", `${id} has no ${action.kind} action.`);
    if (!allowTiers.includes(declared)) {
      throw new BackendRefusal("tier-not-allowed", `${id} ${action.kind} is ${declared}, which allowTiers (${allowTiers.join(", ")}) does not include. Nothing was sent.`);
    }
    return declared;
  }

  async act(
    id: string,
    targetId: string,
    action: BackendAction,
    opts: { observationId: string; allowTiers: BackendTier[] },
    input?: BackendCallInput,
  ): Promise<BackendActResult & { declaredTier: BackendTier; tierExceeded: boolean }> {
    const declaredTier = this.gate(id, action, opts.allowTiers);
    const result = await this.get(id).act(this.call(input), targetId, action, opts);
    // A backend may report a higher rung than it declared (trycua-cua reads it back from the driver).
    return { ...result, declaredTier, tierExceeded: !opts.allowTiers.includes(result.tierUsed) };
  }

  async dispose(): Promise<void> {
    const live = [...this.live.values()];
    this.live.clear();
    await Promise.allSettled(live.map((backend) => backend.dispose()));
  }
}
