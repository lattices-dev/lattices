import { readFile } from "node:fs/promises";
import { extname, isAbsolute, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { AgentLayerStatus, Bounds, RuntimeAction } from "@action/protocol";
import {
  FOCUSED_RECT_SCRIPT,
  clickAt,
  devToolsKey,
  dragBetween,
  findElementScript,
  fromPage,
  insertText,
  pageOnLayer,
  pressKey,
  toPage,
  wheelAt,
  type AgentLayerMark,
  type AgentLayerSnapshot,
  type DevToolsPage,
  type PageGeometry,
} from "@action/runtime";
import { primitiveAction, readPoint, readSpace, toGlobal, type LayerPoint, type LayerPrimitive, type LayerView } from "./layer-primitives.js";

/**
 * One way to drive the agent layer, whichever door the agent comes in by: a single
 * tool call, a list of steps, a steps file, or a script that gets the driver as a
 * function argument.
 *
 * Browser sessions only use DevTools. Native sessions use accessibility and blink.
 */

export const LAYER_VERBS = ["click", "type", "press", "go", "drag", "scroll", "js", "wait", "look", "note"] as const;
export type LayerVerb = (typeof LAYER_VERBS)[number];

type Args = Record<string, unknown>;

export interface LayerStep {
  verb: LayerVerb;
  args: Args;
}

export interface LayerDriverDeps {
  status(): Promise<AgentLayerStatus>;
  view(): LayerView | undefined;
  /** Throws when the operator paused or took back the layer. */
  guard(): Promise<void>;
  /** Run an act as a blink through action.act.execute. */
  blink(action: RuntimeAction): Promise<{ host?: string; leaseId?: string }>;
  /** Keep the layer's drive alive for an act that didn't go through act.execute. */
  touch(kind: string): Promise<void>;
  mark(act: AgentLayerMark): Promise<void>;
  look(): Promise<AgentLayerSnapshot>;
  note(text: string): Promise<void>;
  pageOnLayer?: typeof pageOnLayer;
}

export interface LayerSession {
  mode: "browser" | "native";
  pid: number;
  displayId: number;
  startedAt: string;
  browserPid?: number;
}

export async function guardLayerDispatch(expected: AgentLayerStatus, deps: Pick<LayerDriverDeps, "status" | "guard">): Promise<void> {
  const current = await deps.status();
  if (expected.active !== current.active || (expected.active && (!expected.layer || !current.layer
    || expected.layer.pid !== current.layer.pid || expected.layer.displayId !== current.layer.displayId
    || expected.layer.startedAt !== current.layer.startedAt))) {
    throw new Error("The agent layer session ended or was replaced before input dispatch. Refusing to change input routes.");
  }
  await deps.guard();
}

/** How long the viewer's pointer gets to reach a spot before the act lands there. */
const AIM_LEAD_MS = 260;

const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));

function isVerb(key: string): key is LayerVerb {
  return (LAYER_VERBS as readonly string[]).includes(key);
}

function isRecord(value: unknown): value is Args {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

/**
 * A step as written to its verb and arguments. Each verb has a short form:
 *
 *   { click: "Search" }            label        { click: [420, 310] }   point
 *   { type: "hello\n" }            text         { press: "cmd+l" }      key
 *   { go: "news.ycombinator.com" } url          { scroll: -400 }        dy, mid-view
 *   { drag: [[x, y], [x, y]] }     from, to     { wait: 500 }           ms
 *   { wait: "settled" }            until still  { wait: "Sign in" }     until text shows
 *   { js: "document.title" }       code         { note: "Opening" }     viewer note
 *   { look: true }                 snapshot
 *
 * The long form is an object under the verb ({ click: { label, holdMs } }) or
 * { do: "click", ...args }. Keys next to the verb are extra arguments.
 */
export function parseLayerStep(raw: unknown): LayerStep {
  if (!isRecord(raw)) {
    throw new Error(`A step is an object such as { click: "Search" }, not ${JSON.stringify(raw)}`);
  }
  if (typeof raw.do === "string") {
    if (!isVerb(raw.do)) throw new Error(`Unknown step "${raw.do}". Steps: ${LAYER_VERBS.join(", ")}`);
    const { do: _do, ...args } = raw;
    return { verb: raw.do, args };
  }
  const verbs = Object.keys(raw).filter(isVerb);
  if (verbs.length !== 1) {
    throw new Error(
      verbs.length === 0
        ? `A step names one of ${LAYER_VERBS.join(", ")}: ${JSON.stringify(raw)}`
        : `A step names one verb, not ${verbs.join(" and ")}`,
    );
  }
  const verb = verbs[0]!;
  const { [verb]: value, ...extra } = raw;
  return { verb, args: { ...shorthand(verb, value), ...extra } };
}

function shorthand(verb: LayerVerb, value: unknown): Args {
  if (isRecord(value) && !(verb === "click" && readPoint(value))) {
    return value;
  }
  switch (verb) {
    case "click":
      if (typeof value === "string") return { label: value };
      if (readPoint(value)) return { at: value };
      break;
    case "type":
      if (typeof value === "string") return { text: value };
      break;
    case "press":
      if (typeof value === "string") return { key: value };
      break;
    case "go":
      if (typeof value === "string") return { url: value };
      break;
    case "drag":
      if (Array.isArray(value) && value.length === 2) return { from: value[0], to: value[1] };
      break;
    case "scroll":
      if (typeof value === "number") return { dy: value };
      break;
    case "wait":
      if (typeof value === "number") return { ms: value };
      if (value === "settled") return { until: "settled" };
      if (typeof value === "string") return { text: value };
      break;
    case "js":
      if (typeof value === "string") return { code: value };
      break;
    case "note":
      if (typeof value === "string") return { text: value };
      break;
    case "look":
      return {};
  }
  throw new Error(`${verb} doesn't take ${JSON.stringify(value)}`);
}

/** Steps from a run call: inline, or a JSON file of steps (an array, or { steps }). */
export function parseLayerSteps(raw: unknown): LayerStep[] {
  const list = isRecord(raw) && Array.isArray(raw.steps) ? raw.steps : raw;
  if (!Array.isArray(list) || list.length === 0) {
    throw new Error("steps is a non-empty list, e.g. [{ go: \"example.com\" }, { click: \"More information\" }]");
  }
  return list.map((step, index) => {
    try {
      return parseLayerStep(step);
    } catch (error) {
      throw new Error(`step ${index + 1}: ${(error as Error).message}`);
    }
  });
}

export function normalizeUrl(value: string): string {
  const url = value.trim();
  if (/^[a-z][a-z0-9+.-]*:/i.test(url)) return url;
  if (url.startsWith("/") || url.startsWith("~")) return `file://${url}`;
  return `https://${url}`;
}

/** What a script file gets: one method per verb, taking the same short forms. */
export type LayerScriptApi = {
  [verb in LayerVerb]: (value?: unknown, extra?: Args) => Promise<Record<string, unknown>>;
} & {
  step(step: unknown): Promise<Record<string, unknown>>;
  status(): Promise<AgentLayerStatus>;
};

interface BrowserPage {
  page: DevToolsPage;
  geometry: PageGeometry;
}

export class LayerDriver {
  private session: LayerSession | undefined;

  constructor(private readonly deps: LayerDriverDeps) {}

  bind(status: AgentLayerStatus, mode: LayerSession["mode"], browserPid?: number): LayerSession {
    if (!status.active || !status.layer) throw new Error("Cannot bind an inactive agent layer.");
    if (mode === "browser" && !browserPid) throw new Error("Browser sessions require their owned browser pid.");
    const { pid, displayId, startedAt } = status.layer;
    this.session = Object.freeze({ mode, pid, displayId, startedAt, ...(browserPid ? { browserPid } : {}) });
    return this.session;
  }

  release(): void {
    this.session = undefined;
  }

  identity(): LayerSession | undefined {
    return this.session ? { ...this.session } : undefined;
  }

  async assertSession(expected = this.session): Promise<AgentLayerStatus> {
    if (!expected || this.session !== expected) throw new Error("No bound agent layer session. Open one with action.layer.open.");
    const status = await this.deps.status();
    if (this.session !== expected || !status.active || !status.layer || status.layer.pid !== expected.pid
      || status.layer.displayId !== expected.displayId || status.layer.startedAt !== expected.startedAt) {
      throw new Error("The agent layer session ended or was replaced. Stop interactions and explicitly open a new session.");
    }
    return status;
  }

  async step(step: LayerStep, session = this.session): Promise<Record<string, unknown>> {
    const status = await this.assertSession(session);
    if (step.verb === "note") {
      const text = typeof step.args.text === "string" ? step.args.text : "";
      await this.deps.note(text);
      return { session, note: text };
    }
    if (step.verb === "look") {
      return { session, snapshot: await this.deps.look() };
    }
    if (step.verb === "wait") {
      return { session, ...await this.wait(step.args, session!) };
    }
    await this.deps.guard();
    if (session!.mode === "native") {
      await this.assertSession(session);
      return { ...await this.viaBlink(step, status), session };
    }
    const near = this.pointOf(step, status.layer!.bounds);
    const browser = await this.browser(status, near);
    try {
      if (!browser) throw new Error("Browser session has no reachable DevTools page on its layer. Native input fallback is disabled.");
      await this.assertSession(session);
      const result = await this.viaDevTools(step, browser, status.layer!.bounds, session!);
      if (!result) throw new Error(`Browser session cannot perform ${step.verb} through DevTools on this page. Native input fallback is disabled; use a page target or layer.go for navigation.`);
      await this.assertSession(session);
      await this.deps.touch(step.verb);
      return { route: "devtools", session, pageTargetId: browser.page.target.id, ...result };
    } finally {
      browser?.page.close();
    }
  }

  /** The script-file face of the driver. */
  api(): LayerScriptApi {
    const session = this.session;
    const step = async (value: LayerStep) => {
      await this.assertSession(session);
      return this.step(value, session);
    };
    const api: Record<string, unknown> = {
      step: (value: unknown) => step(parseLayerStep(value)),
      status: () => this.assertSession(session),
    };
    for (const verb of LAYER_VERBS) {
      api[verb] = (value?: unknown, extra: Args = {}) =>
        step({ verb, args: { ...shorthand(verb, verb === "look" ? true : value), ...extra } });
    }
    return api as LayerScriptApi;
  }

  /**
   * Run steps in order. Stops at the first that fails and says which, with a look at
   * the layer, so the caller sees where it got to.
   */
  async run(steps: LayerStep[], session = this.session): Promise<{ ok: boolean; steps: Record<string, unknown>[]; failed?: { step: number; verb: LayerVerb; error: string } }> {
    const results: Record<string, unknown>[] = [];
    for (const [index, step] of steps.entries()) {
      try {
        await this.assertSession(session);
        const started = Date.now();
        const result = summarize(await this.step(step, session));
        results.push({ [step.verb]: result, ms: Date.now() - started });
      } catch (error) {
        return { ok: false, steps: results, failed: { step: index + 1, verb: step.verb, error: (error as Error).message } };
      }
    }
    return { ok: true, steps: results };
  }

  /** A .json file of steps, or a .ts/.js module whose default export is `async (layer) => …`. */
  async runFile(path: string): Promise<Record<string, unknown>> {
    const session = this.session;
    const api = this.api();
    const file = isAbsolute(path) ? path : resolve(process.cwd(), path);
    const ext = extname(file).toLowerCase();
    if (ext === ".json") {
      return this.run(parseLayerSteps(JSON.parse(await readFile(file, "utf8"))), session);
    }
    if ([".ts", ".js", ".mjs", ".mts"].includes(ext)) {
      // Cache-busted so an edited script runs as edited.
      const module = await import(`${pathToFileURL(file).href}?at=${Date.now()}`) as { default?: unknown };
      if (typeof module.default !== "function") {
        throw new Error(`${path} needs a default export: export default async (layer) => { await layer.click("Search") }`);
      }
      try {
        await this.assertSession(session);
        const value = await (module.default as (layer: LayerScriptApi) => unknown)(api);
        return { ok: true, ...(value !== undefined ? { value } : {}) };
      } catch (error) {
        return { ok: false, error: (error as Error).message };
      }
    }
    throw new Error(`Run a .json steps file or a .ts/.js script, not ${ext || "a file without an extension"}`);
  }

  private pointOf(step: LayerStep, bounds: Bounds): LayerPoint | undefined {
    const raw = step.verb === "drag" ? readPoint(step.args.from) : readAt(step.args);
    return raw ? toGlobal(raw, readSpace(step.args.space), bounds, this.deps.view()) : undefined;
  }

  private async browser(status: AgentLayerStatus, near?: LayerPoint): Promise<BrowserPage | undefined> {
    const pids = new Set<number>();
    if (this.session?.mode === "browser") pids.add(this.session.browserPid!);
    else return undefined;
    for (const pid of pids) {
      const found = await (this.deps.pageOnLayer ?? pageOnLayer)(pid, status.layer!.bounds, near).catch(() => undefined);
      if (found) {
        // A background window's page still takes focus and caret as if it were in front.
        await found.page.call("Emulation.setFocusEmulationEnabled", { enabled: true }).catch(() => undefined);
        return found;
      }
    }
    return undefined;
  }

  /** The act through DevTools, or undefined when the page cannot handle it. */
  private async viaDevTools(step: LayerStep, { page, geometry }: BrowserPage, bounds: Bounds, session: LayerSession): Promise<Record<string, unknown> | undefined> {
    const args = step.args;
    const global = (point: LayerPoint) => toGlobal(point, readSpace(args.space), bounds, this.deps.view());
    const guard = async () => {
      await this.assertSession(session);
      await this.deps.guard();
    };
    switch (step.verb) {
      case "click": {
        let at: LayerPoint;
        let found: Record<string, unknown> | undefined;
        if (typeof args.label === "string" || typeof args.selector === "string") {
          const rect = await page.evaluate<{ x: number; y: number; width: number; height: number; tag: string; text: string } | null>(
            findElementScript({
              ...(typeof args.label === "string" ? { label: args.label } : {}),
              ...(typeof args.selector === "string" ? { selector: args.selector } : {}),
            }),
          );
          if (!rect) {
            if (typeof args.selector === "string") throw new Error(`Nothing visible matches ${args.selector}`);
            return undefined;
          }
          const frame = fromPage(geometry, rect);
          at = { x: frame.x + frame.width / 2, y: frame.y + frame.height / 2 };
          found = { tag: rect.tag, text: rect.text };
        } else {
          const point = readAt(args);
          if (!point) throw new Error("click needs a label, a selector, or a point: { click: \"Search\" } or { click: [x, y] }");
          at = global(point);
        }
        const inPage = toPage(geometry, at);
        if (!within(geometry, inPage)) return undefined;
        await this.aim(at);
        await clickAt(page, inPage, finite(args.holdMs) ?? 0, guard);
        await this.deps.mark({ kind: "click", point: at });
        return { at: round(at), ...(found ? { element: found } : {}) };
      }
      case "type": {
        if (typeof args.text !== "string" || args.text === "") throw new Error('type needs text. End it with "\\n" to submit.');
        await this.markFocused(page, geometry);
        await insertText(page, args.text, guard);
        return { text: args.text };
      }
      case "press": {
        if (typeof args.key !== "string") throw new Error('press needs key: "return", "cmd+l", "⌘⇧T"…');
        const key = devToolsKey(args.key);
        if (!key) return undefined;
        await this.markFocused(page, geometry);
        await pressKey(page, key, guard);
        return { key: args.key };
      }
      case "go": {
        if (typeof args.url !== "string" || !args.url.trim()) throw new Error("go needs url");
        const url = normalizeUrl(args.url);
        await guard();
        const reply = await page.call<{ errorText?: string }>("Page.navigate", { url });
        if (reply.errorText) throw new Error(`${url}: ${reply.errorText}`);
        await waitFor(page, "document.readyState !== 'loading'", 10_000);
        return { url, title: await page.evaluate<string>("document.title") };
      }
      case "drag": {
        const from = readPoint(args.from);
        const to = readPoint(args.to);
        if (!from || !to) throw new Error("drag needs from and to: { drag: [[x, y], [x, y]] }");
        const a = global(from);
        const b = global(to);
        if (!within(geometry, toPage(geometry, a)) || !within(geometry, toPage(geometry, b))) return undefined;
        await this.aim(a);
        await dragBetween(page, toPage(geometry, a), toPage(geometry, b), finite(args.durationMs) ?? 200, guard);
        await this.deps.mark({ kind: "drag", point: b, from: a });
        return { from: round(a), to: round(b) };
      }
      case "scroll": {
        const dy = finite(args.dy) ?? 0;
        const dx = finite(args.dx) ?? 0;
        if (dx === 0 && dy === 0) throw new Error("scroll needs dy or dx (wheel pixels; positive dy scrolls up)");
        const point = readAt(args);
        const at = point
          ? global(point)
          : { x: geometry.origin.x + (geometry.width * geometry.zoom) / 2, y: geometry.origin.y + (geometry.height * geometry.zoom) / 2 };
        const inPage = toPage(geometry, at);
        if (!within(geometry, inPage)) return undefined;
        await this.aim(at);
        await guard();
        await wheelAt(page, inPage, dx, dy);
        await this.deps.mark({ kind: "scroll", point: at, dy });
        return { at: round(at), dy, ...(dx ? { dx } : {}) };
      }
      case "js": {
        if (typeof args.code !== "string" || !args.code.trim()) throw new Error("js needs code");
        await guard();
        return { value: await page.evaluate(args.code) };
      }
      default:
        return undefined;
    }
  }

  private async viaBlink(step: LayerStep, status: AgentLayerStatus): Promise<Record<string, unknown>> {
    const subjectBundleId = status.subject?.bundleId ?? status.layer?.windows[0]?.bundleId ?? undefined;
    let action: RuntimeAction;
    switch (step.verb) {
      case "js":
        throw new Error("js runs in a browser page: open the layer with { browser: true } (Chrome with a DevTools port).");
      case "go": {
        if (typeof step.args.url !== "string" || !step.args.url.trim()) throw new Error("go needs url");
        if (!subjectBundleId) throw new Error("go needs the layer opened on an app (bundleId).");
        const url = normalizeUrl(step.args.url);
        action = {
          id: `layer_go_${Date.now().toString(36)}`,
          kind: "open-app",
          description: `open ${url}`,
          input: { bundleId: subjectBundleId, url, background: true },
        };
        break;
      }
      default:
        action = primitiveAction(step.verb as LayerPrimitive, step.args, {
          bounds: status.layer!.bounds,
          view: this.deps.view(),
          ...(subjectBundleId ? { subjectBundleId } : {}),
        });
    }
    const executed = await this.deps.blink(action);
    return { route: "blink", ...(action.input ?? {}), ...(executed.host ? { host: executed.host } : {}) };
  }

  private async wait(args: Args, session: LayerSession): Promise<Record<string, unknown>> {
    const ms = finite(args.ms);
    if (ms !== undefined) {
      await sleep(Math.min(ms, 30_000));
      await this.assertSession(session);
      return { ms };
    }
    const budget = Math.min(finite(args.timeoutMs) ?? 8_000, 30_000);
    const started = Date.now();
    if (typeof args.text === "string") {
      const status = await this.assertSession(session);
      const browser = status.layer ? await this.browser(status) : undefined;
      if (!browser) throw new Error("wait for text reads a browser page: open the layer with { browser: true }, or wait for ms.");
      try {
        await waitFor(browser.page, `document.body && document.body.innerText.includes(${JSON.stringify(args.text)})`, budget);
      } finally {
        browser.page.close();
      }
      await this.assertSession(session);
      return { text: args.text, ms: Date.now() - started };
    }
    // Settled: the page done loading, if there is one, and the layer still for a beat.
    // A page's still beat is shorter and capped, since a blinking caret never stops.
    const status = await this.assertSession(session);
    const browser = status.layer ? await this.browser(status) : undefined;
    if (session.mode === "browser" && !browser) throw new Error("Browser session has no reachable DevTools page. Native input fallback is disabled.");
    if (browser) {
      try {
        await waitFor(browser.page, "document.readyState === 'complete'", budget).catch(() => undefined);
      } finally {
        browser.page.close();
      }
    }
    const still = browser ? 250 : 400;
    const deadline = browser ? Math.min(started + budget, Date.now() + 1_500) : started + budget;
    for (;;) {
      await this.assertSession(session);
      const snapshot = await this.deps.look();
      if ((snapshot.unchangedMs ?? 0) >= still || Date.now() >= deadline) {
        return { until: "settled", ms: Date.now() - started, unchangedMs: snapshot.unchangedMs };
      }
      await sleep(120);
    }
  }

  private async aim(point: LayerPoint): Promise<void> {
    await this.deps.mark({ kind: "aim", point });
    await sleep(AIM_LEAD_MS);
  }

  private async markFocused(page: DevToolsPage, geometry: PageGeometry): Promise<void> {
    const rect = await page.evaluate<{ x: number; y: number; width: number; height: number } | null>(FOCUSED_RECT_SCRIPT).catch(() => null);
    if (rect) await this.deps.mark({ kind: "field", frame: fromPage(geometry, rect) });
  }
}

function finite(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function readAt(args: Args): LayerPoint | undefined {
  const x = finite(args.x);
  const y = finite(args.y);
  return x !== undefined && y !== undefined ? { x, y } : readPoint(args.at);
}

function within(geometry: PageGeometry, point: LayerPoint): boolean {
  return point.x >= 0 && point.y >= 0 && point.x < geometry.width && point.y < geometry.height;
}

function round(point: LayerPoint): LayerPoint {
  return { x: Math.round(point.x), y: Math.round(point.y) };
}

async function waitFor(page: DevToolsPage, condition: string, budgetMs: number): Promise<void> {
  const deadline = Date.now() + budgetMs;
  for (;;) {
    if (await page.evaluate<boolean>(`Boolean(${condition})`).catch(() => false)) return;
    if (Date.now() >= deadline) throw new Error(`timed out after ${budgetMs}ms waiting for ${condition}`);
    await sleep(100);
  }
}

/** A step's result for a run's log: the snapshot path, not the whole snapshot. */
function summarize(result: Record<string, unknown>): Record<string, unknown> {
  const snapshot = result.snapshot as AgentLayerSnapshot | undefined;
  return snapshot ? { ...result, snapshot: { path: snapshot.path, width: snapshot.width, height: snapshot.height } } : result;
}
