import { execFile } from "node:child_process";
import { readdirSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { promisify } from "node:util";
import type { Bounds } from "@action/protocol";
import { agentWorkspaceSerial, parseAgentWorkspace } from "./agent-layer.js";

/**
 * A Chromium browser on the agent layer, driven through its DevTools port instead of
 * the pointer and keyboard. Input goes straight to the page's renderer: nothing on the
 * operator's screens moves and the browser never comes forward.
 *
 * Only a browser launched with --remote-debugging-port has one (Action's own Chrome
 * profiles do). Anything else keeps the accessibility and blink routes.
 */

const run = promisify(execFile);
const CALL_TIMEOUT_MS = 10_000;

export interface LayerPoint {
  x: number;
  y: number;
}

interface Target {
  id: string;
  type: string;
  url: string;
  title: string;
  webSocketDebuggerUrl?: string;
}

/** Where a page's viewport sits in global top-left points, and its zoom. */
export interface PageGeometry {
  /** Global point of the viewport's top-left corner. */
  origin: LayerPoint;
  /** Screen points per CSS pixel. */
  zoom: number;
  width: number;
  height: number;
  visible: boolean;
}

/** The debugging port in a process's command line, if it was launched with one. */
export async function debugPortOf(pid: number): Promise<number | undefined> {
  try {
    const { stdout } = await run("/bin/ps", ["-o", "command=", "-p", String(pid)]);
    return parseDebugPort(stdout);
  } catch {
    return undefined;
  }
}

export function parseDebugPort(commandLine: string): number | undefined {
  const match = /--remote-debugging-port=(\d+)/.exec(commandLine);
  const port = match ? Number(match[1]) : 0;
  return port > 0 ? port : undefined;
}

/**
 * The viewport from what the page reports: screenX/Y is the window's top-left, and the
 * browser chrome sits above the viewport. Zoom is outer points over CSS pixels, read
 * from the width, where there is no toolbar.
 */
export function pageGeometry(input: {
  screenX: number;
  screenY: number;
  outerWidth: number;
  outerHeight: number;
  innerWidth: number;
  innerHeight: number;
  visible: boolean;
}): PageGeometry {
  const zoom = input.innerWidth > 0 && input.outerWidth > 0 ? input.outerWidth / input.innerWidth : 1;
  const rounded = Math.abs(zoom - 1) < 0.02 ? 1 : zoom;
  return {
    origin: {
      x: input.screenX,
      y: input.screenY + input.outerHeight - input.innerHeight * rounded,
    },
    zoom: rounded,
    width: input.innerWidth,
    height: input.innerHeight,
    visible: input.visible,
  };
}

export function contains(bounds: Bounds, point: LayerPoint): boolean {
  return point.x >= bounds.x && point.y >= bounds.y
    && point.x < bounds.x + bounds.width && point.y < bounds.y + bounds.height;
}

/** One DevTools connection to a page. */
export class DevToolsPage {
  private nextId = 1;
  private readonly pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();

  private constructor(private readonly socket: WebSocket, readonly target: Target) {
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data)) as { id?: number; result?: unknown; error?: { message?: string } };
      const waiter = message.id !== undefined ? this.pending.get(message.id) : undefined;
      if (!waiter) return;
      this.pending.delete(message.id!);
      if (message.error) waiter.reject(new Error(message.error.message ?? "DevTools error"));
      else waiter.resolve(message.result);
    });
    socket.addEventListener("close", () => {
      for (const waiter of this.pending.values()) waiter.reject(new Error("DevTools connection closed"));
      this.pending.clear();
    });
  }

  static async connect(target: Target): Promise<DevToolsPage> {
    const socket = new WebSocket(target.webSocketDebuggerUrl!);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("DevTools connection timed out")), CALL_TIMEOUT_MS);
      socket.addEventListener("open", () => { clearTimeout(timer); resolve(); }, { once: true });
      socket.addEventListener("error", () => { clearTimeout(timer); reject(new Error("DevTools connection failed")); }, { once: true });
    });
    return new DevToolsPage(socket, target);
  }

  call<T = Record<string, unknown>>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, CALL_TIMEOUT_MS);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value as T); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  /** Run an expression in the page and return its value; promises are awaited. */
  async evaluate<T = unknown>(expression: string): Promise<T> {
    const reply = await this.call<{ result?: { value?: T }; exceptionDetails?: { text?: string; exception?: { description?: string } } }>(
      "Runtime.evaluate",
      { expression, returnByValue: true, awaitPromise: true, userGesture: true },
    );
    if (reply.exceptionDetails) {
      throw new Error(reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text ?? "script threw");
    }
    return reply.result?.value as T;
  }

  async geometry(): Promise<PageGeometry> {
    const raw = await this.evaluate<Parameters<typeof pageGeometry>[0]>(
      "({ screenX, screenY, outerWidth, outerHeight, innerWidth, innerHeight, visible: document.visibilityState === 'visible' })",
    );
    return pageGeometry(raw);
  }

  close(): void {
    this.socket.close();
  }
}

/**
 * The page showing on the layer: the visible tab whose window sits inside the layer's
 * bounds, nearest `near` when several windows are there. Undefined when the browser
 * has no debugging port or no such page.
 */
export async function pageOnLayer(
  pid: number,
  bounds: Bounds,
  near?: LayerPoint,
): Promise<{ page: DevToolsPage; geometry: PageGeometry; port: number } | undefined> {
  const port = await debugPortOf(pid);
  if (!port) return undefined;
  let targets: Target[];
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(2_000) });
    targets = (await response.json() as Target[]).filter((target) => target.type === "page" && target.webSocketDebuggerUrl);
  } catch {
    return undefined;
  }
  let best: { page: DevToolsPage; geometry: PageGeometry; distance: number } | undefined;
  for (const target of targets) {
    let page: DevToolsPage;
    try {
      page = await DevToolsPage.connect(target);
    } catch {
      continue;
    }
    const geometry = await page.geometry().catch(() => undefined);
    const center = geometry && {
      x: geometry.origin.x + (geometry.width * geometry.zoom) / 2,
      y: geometry.origin.y + (geometry.height * geometry.zoom) / 2,
    };
    if (!geometry?.visible || !center || !contains(bounds, center)) {
      page.close();
      continue;
    }
    const inside = near ? isInside(geometry, near) : true;
    const distance = near ? (inside ? 0 : Math.hypot(center.x - near.x, center.y - near.y)) : 0;
    if (!best || distance < best.distance) {
      best?.page.close();
      best = { page, geometry, distance };
    } else {
      page.close();
    }
  }
  return best && { page: best.page, geometry: best.geometry, port };
}

function isInside(geometry: PageGeometry, point: LayerPoint): boolean {
  return point.x >= geometry.origin.x && point.y >= geometry.origin.y
    && point.x < geometry.origin.x + geometry.width * geometry.zoom
    && point.y < geometry.origin.y + geometry.height * geometry.zoom;
}

/** A global point to the page's CSS pixels. */
export function toPage(geometry: PageGeometry, point: LayerPoint): LayerPoint {
  return {
    x: (point.x - geometry.origin.x) / geometry.zoom,
    y: (point.y - geometry.origin.y) / geometry.zoom,
  };
}

/** A CSS rect in the page to global points. */
export function fromPage(geometry: PageGeometry, rect: { x: number; y: number; width: number; height: number }): Bounds {
  return {
    x: geometry.origin.x + rect.x * geometry.zoom,
    y: geometry.origin.y + rect.y * geometry.zoom,
    width: rect.width * geometry.zoom,
    height: rect.height * geometry.zoom,
  };
}

/**
 * Finds the element a label or selector names, scrolls it into view, and returns its
 * rect. A label matches visible text, aria-label, title, placeholder or value of a
 * clickable or editable element; exact matches win over partial ones.
 */
export function findElementScript(query: { label?: string; selector?: string }): string {
  return `(() => {
  const query = ${JSON.stringify(query)};
  const visible = (el) => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
  let el;
  if (query.selector) {
    el = [...document.querySelectorAll(query.selector)].find(visible);
  } else {
    const want = query.label.trim().toLowerCase();
    const names = (el) => [el.getAttribute('aria-label'), el.getAttribute('title'), el.getAttribute('placeholder'), el.getAttribute('alt'), el.value, el.innerText, el.textContent]
      .filter((v) => typeof v === 'string').map((v) => v.replace(/\\s+/g, ' ').trim().toLowerCase()).filter(Boolean);
    const candidates = [...document.querySelectorAll('a, button, input, textarea, select, summary, label, [role], [onclick], [tabindex], [contenteditable=""], [contenteditable="true"]')].filter(visible);
    el = candidates.find((c) => names(c).some((n) => n === want))
      ?? candidates.find((c) => names(c).some((n) => n.startsWith(want)))
      ?? candidates.find((c) => names(c).some((n) => n.includes(want)));
  }
  if (!el) return null;
  el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  const r = el.getBoundingClientRect();
  return { x: r.x, y: r.y, width: r.width, height: r.height, tag: el.tagName.toLowerCase(), text: (el.getAttribute('aria-label') || el.innerText || el.value || '').trim().slice(0, 80) };
})()`;
}

/** The focused element's rect, for the viewer's field mark. */
export const FOCUSED_RECT_SCRIPT = `(() => {
  const el = document.activeElement;
  if (!el || el === document.body) return null;
  const r = el.getBoundingClientRect();
  return { x: r.x, y: r.y, width: r.width, height: r.height };
})()`;

const KEY_CODES: Record<string, { key: string; code: string; keyCode: number; text?: string }> = {
  return: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
  enter: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
  tab: { key: "Tab", code: "Tab", keyCode: 9 },
  escape: { key: "Escape", code: "Escape", keyCode: 27 },
  esc: { key: "Escape", code: "Escape", keyCode: 27 },
  space: { key: " ", code: "Space", keyCode: 32, text: " " },
  delete: { key: "Backspace", code: "Backspace", keyCode: 8 },
  backspace: { key: "Backspace", code: "Backspace", keyCode: 8 },
  forwarddelete: { key: "Delete", code: "Delete", keyCode: 46 },
  up: { key: "ArrowUp", code: "ArrowUp", keyCode: 38 },
  down: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
  left: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
  right: { key: "ArrowRight", code: "ArrowRight", keyCode: 39 },
  home: { key: "Home", code: "Home", keyCode: 36 },
  end: { key: "End", code: "End", keyCode: 35 },
  pageup: { key: "PageUp", code: "PageUp", keyCode: 33 },
  pagedown: { key: "PageDown", code: "PageDown", keyCode: 34 },
};

const MODIFIER_BITS: Record<string, number> = { alt: 1, option: 1, ctrl: 2, control: 2, cmd: 4, command: 4, meta: 4, shift: 8 };

/**
 * A chord as DevTools key events, or undefined when it should not go this way.
 * Command chords are the browser's shortcuts (⌘L, ⌘T), which DevTools key events never
 * reach, so they stay on the menu route.
 */
export function devToolsKey(chord: string): { modifiers: number; key: string; code: string; keyCode: number; text?: string } | undefined {
  const parts = chord.toLowerCase().split("+").map((part) => part.trim()).filter(Boolean);
  const name = parts.pop();
  if (!name) return undefined;
  let modifiers = 0;
  for (const part of parts) {
    const bit = MODIFIER_BITS[part];
    if (bit === undefined) return undefined;
    modifiers |= bit;
  }
  if (modifiers & 4) return undefined;
  const named = KEY_CODES[name];
  if (named) return { modifiers, ...(modifiers & ~8 ? { ...named, text: undefined } : named) };
  if (name.length === 1) {
    const upper = name.toUpperCase();
    const letter = /[a-z]/.test(name);
    const text = modifiers === 8 ? upper : modifiers === 0 ? name : undefined;
    return {
      modifiers,
      key: text ?? name,
      code: letter ? `Key${upper}` : /[0-9]/.test(name) ? `Digit${name}` : "",
      keyCode: upper.charCodeAt(0),
      ...(text ? { text } : {}),
    };
  }
  return undefined;
}

type InputGuard = () => Promise<void>;

export async function pressKey(page: DevToolsPage, key: NonNullable<ReturnType<typeof devToolsKey>>, guard?: InputGuard): Promise<void> {
  const base = { modifiers: key.modifiers, key: key.key, code: key.code, windowsVirtualKeyCode: key.keyCode };
  await guard?.();
  try {
    await page.call("Input.dispatchKeyEvent", { type: key.text ? "keyDown" : "rawKeyDown", ...base, ...(key.text ? { text: key.text, unmodifiedText: key.text } : {}) });
  } finally {
    await page.call("Input.dispatchKeyEvent", { type: "keyUp", ...base });
  }
}

export async function clickAt(page: DevToolsPage, point: LayerPoint, holdMs = 0, guard?: InputGuard): Promise<void> {
  await guard?.();
  await page.call("Input.dispatchMouseEvent", { type: "mouseMoved", x: point.x, y: point.y });
  await guard?.();
  try {
    await page.call("Input.dispatchMouseEvent", { type: "mousePressed", x: point.x, y: point.y, button: "left", buttons: 1, clickCount: 1 });
    if (holdMs > 0) await new Promise((done) => setTimeout(done, holdMs));
    await guard?.();
  } finally {
    await page.call("Input.dispatchMouseEvent", { type: "mouseReleased", x: point.x, y: point.y, button: "left", buttons: 0, clickCount: 1 });
  }
}

export async function dragBetween(page: DevToolsPage, from: LayerPoint, to: LayerPoint, durationMs = 200, guard?: InputGuard): Promise<void> {
  const steps = Math.max(4, Math.round(durationMs / 16));
  let lastPoint = from;
  await guard?.();
  await page.call("Input.dispatchMouseEvent", { type: "mouseMoved", x: from.x, y: from.y });
  await guard?.();
  try {
    await page.call("Input.dispatchMouseEvent", { type: "mousePressed", x: from.x, y: from.y, button: "left", buttons: 1, clickCount: 1 });
    for (let step = 1; step <= steps; step += 1) {
      await guard?.();
      const progress = step / steps;
      lastPoint = { x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress };
      await page.call("Input.dispatchMouseEvent", {
        type: "mouseMoved",
        ...lastPoint,
        button: "left",
        buttons: 1,
      });
      await new Promise((done) => setTimeout(done, durationMs / steps));
    }
    await guard?.();
  } finally {
    await page.call("Input.dispatchMouseEvent", { type: "mouseReleased", ...lastPoint, button: "left", buttons: 0, clickCount: 1 });
  }
}

/** dy as the layer reads it: positive is a wheel turned up. DevTools counts the other way. */
export async function wheelAt(page: DevToolsPage, point: LayerPoint, dx: number, dy: number): Promise<void> {
  await page.call("Input.dispatchMouseEvent", { type: "mouseWheel", x: point.x, y: point.y, deltaX: -dx, deltaY: -dy });
}

/** Text into the focused element; each "\n" is a Return. */
export async function insertText(page: DevToolsPage, text: string, guard?: InputGuard): Promise<void> {
  const lines = text.split("\n");
  for (const [index, line] of lines.entries()) {
    if (line) {
      await guard?.();
      await page.call("Input.insertText", { text: line });
    }
    if (index < lines.length - 1) await pressKey(page, devToolsKey("return")!, guard);
  }
}

const CHROME_FOR_TESTING = "com.google.chrome.for.testing";

/**
 * The newest Chrome for Testing under Action's browsers folder (installed with
 * `bunx @puppeteer/browsers install chrome@stable --path <root>`). Its bundle id is its
 * own, so a Spaces "Assign To Desktop" binding on the user's Chrome never pins it.
 */
export function chromeForTestingApp(root = `${process.env.HOME}/Library/Application Support/Action/browsers`): string | undefined {
  try {
    const builds = readdirSync(`${root}/chrome`)
      .filter((name) => name.startsWith("mac"))
      .sort((a, b) => compareVersions(a.split("-").pop() ?? "", b.split("-").pop() ?? ""));
    for (const build of builds.reverse()) {
      for (const dir of readdirSync(`${root}/chrome/${build}`).filter((name) => name.startsWith("chrome-mac"))) {
        const app = `${root}/chrome/${build}/${dir}/Google Chrome for Testing.app`;
        if (readdirSync(`${root}/chrome/${build}/${dir}`).includes("Google Chrome for Testing.app")) return app;
      }
    }
  } catch {}
  return undefined;
}

function compareVersions(a: string, b: string): number {
  const x = a.split(".").map(Number);
  const y = b.split(".").map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i += 1) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

/**
 * Where the layer's browser profile lives, which port it debugs on and which app runs it.
 * Its own port and profile, apart from the browser_* tools' Chrome: that one is the
 * user's Chrome bundle, which a Spaces binding can pin to one Desktop, off the layer.
 */
export function layerBrowserConfig(profile?: string, options: { workspace?: string } = {}): { profileDir: string; port: number; app: string; bundleId: string; profile: string } {
  const workspace = parseAgentWorkspace(options.workspace);
  const root = process.env.ACTION_BROWSER_PROFILE_ROOT
    ?? `${process.env.HOME}/Library/Application Support/Action/ChromeProfiles`;
  const name = profile ?? process.env.ACTION_LAYER_BROWSER_PROFILE ?? "agent-layer";
  if (name.trim() !== name || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(name)) throw new Error("Browser profile must be a simple name, not a path");
  const app = process.env.ACTION_LAYER_BROWSER_APP ?? chromeForTestingApp() ?? "Google Chrome";
  const override = workspace === "default" ? process.env.ACTION_LAYER_BROWSER_PORT
    : process.env[`ACTION_LAYER_BROWSER_PORT_${workspace.toUpperCase().replaceAll("-", "_")}`];
  const port = Number(override ?? (workspace === "default" ? 9335 : 20000 + agentWorkspaceSerial(workspace) % 20000));
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Layer browser port must be an integer between 1024 and 65535");
  return {
    profile: name,
    profileDir: workspace === "default" ? resolve(root, name) : resolve(root, "workspaces", workspace, name),
    port,
    app,
    bundleId: app.endsWith("Google Chrome for Testing.app") ? CHROME_FOR_TESTING : "com.google.Chrome",
  };
}

export function layerBrowserCommandMatches(command: string, config: ReturnType<typeof layerBrowserConfig>): boolean {
  const parts = command.trim().split(/\s+(?=--)/);
  const appName = basename(config.app).replace(/\.app$/, "");
  const executable = `${appName}.app/Contents/MacOS/${appName}`;
  const matchesExecutable = config.app.startsWith("/")
    ? parts[0] === `${config.app}/Contents/MacOS/${appName}`
    : parts[0]?.endsWith(`/${executable}`);
  return Boolean(matchesExecutable)
    && parts.filter(part => part.startsWith("--user-data-dir=")).length === 1
    && parts.includes(`--user-data-dir=${config.profileDir}`)
    && parts.filter(part => part.startsWith("--remote-debugging-port=")).length === 1
    && parts.includes(`--remote-debugging-port=${config.port}`);
}

async function requireLayerBrowserIdentity(pid: number, config: ReturnType<typeof layerBrowserConfig>): Promise<void> {
  const { stdout } = await run("/bin/ps", ["-ww", "-o", "command=", "-p", String(pid)]);
  if (!layerBrowserCommandMatches(stdout, config)) {
    throw new Error(`DevTools port ${config.port} belongs to another process or browser profile; refusing to adopt PID ${pid}`);
  }
}

/** One app's Desktop in `defaults read com.apple.spaces app-bindings` output; keys are lowercased. */
export function parseSpacesBinding(plist: string, bundleId: string): string | undefined {
  for (const line of plist.split("\n")) {
    const match = /^\s*"?([^"=]+?)"?\s*=\s*"?([^";]*)"?;/.exec(line);
    if (match?.[1] === bundleId.toLowerCase()) {
      return match[2] && match[2] !== "AllSpaces" ? match[2] : undefined;
    }
  }
  return undefined;
}

/**
 * The Desktop an app is assigned to in Dock > Options > Assign To, if one. macOS keeps
 * such an app's windows on that Desktop, so they can't show on an agent layer.
 */
export async function spacesBinding(bundleId: string): Promise<string | undefined> {
  try {
    const { stdout } = await run("/usr/bin/defaults", ["read", "com.apple.spaces", "app-bindings"]);
    return parseSpacesBinding(stdout, bundleId);
  } catch {
    return undefined;
  }
}

async function listeningPid(port: number): Promise<number | undefined> {
  try {
    const { stdout } = await run("/usr/sbin/lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"]);
    const pid = Number(stdout.trim().split("\n")[0]);
    return pid > 0 ? pid : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Action's Chrome, running and debuggable: the one already on the port, or a new
 * instance launched hidden on the profile, so its first window never shows on the
 * user's screens. Returns the browser process id.
 */
export async function ensureLayerBrowser(profile?: string, options: { workspace?: string } = {}): Promise<{ pid: number; port: number; profile: string; bundleId: string; launched: boolean }> {
  const config = layerBrowserConfig(profile, options);
  const running = await listeningPid(config.port);
  if (running) {
    await requireLayerBrowserIdentity(running, config);
    await unhide(running);
    return { pid: running, port: config.port, profile: config.profile, bundleId: config.bundleId, launched: false };
  }
  await mkdir(config.profileDir, { recursive: true });
  await run("/usr/bin/open", [
    "-n", "-j", "-g", "-a", config.app, "--args",
    `--user-data-dir=${config.profileDir}`,
    `--remote-debugging-port=${config.port}`,
    "--remote-allow-origins=*",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    // No first window: Chrome brings itself forward with it. The window is made on the
    // layer afterwards, by openBrowserWindow.
    "--no-startup-window",
  ]);
  for (let attempt = 0; attempt < 60; attempt += 1) {
    const pid = await listeningPid(config.port);
    if (pid) {
      await requireLayerBrowserIdentity(pid, config);
      await unhide(pid);
      return { pid, port: config.port, profile: config.profile, bundleId: config.bundleId, launched: true };
    }
    await new Promise((done) => setTimeout(done, 250));
  }
  throw new Error(`${config.app} did not open its DevTools port ${config.port}`);
}

/**
 * `open -j` launches the app hidden, and a hidden app's windows never draw, on the layer
 * or anywhere. Showing it again doesn't activate it; it has no windows on the user's
 * screens to show.
 */
async function unhide(pid: number): Promise<void> {
  await run("/usr/bin/osascript", [
    "-e", `tell application "System Events" to set visible of (first process whose unix id is ${pid}) to true`,
  ]).catch(() => undefined);
}

/**
 * A new browser window made straight on the layer through DevTools, so it never shows
 * on the user's screens and nothing asks Launch Services, which could hand the request
 * to the user's own Chrome.
 */
export async function openBrowserWindow(port: number, bounds: Bounds, url = "about:blank"): Promise<string> {
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(2_000) })).json() as { webSocketDebuggerUrl: string };
  const browser = await DevToolsPage.connect({ id: "browser", type: "browser", url: "", title: "", webSocketDebuggerUrl: version.webSocketDebuggerUrl });
  try {
    const { targetId } = await browser.call<{ targetId: string }>("Target.createTarget", {
      url,
      newWindow: true,
      background: true,
      left: Math.round(bounds.x),
      top: Math.round(bounds.y),
      width: Math.round(bounds.width),
      height: Math.round(bounds.height),
    });
    return targetId;
  } finally {
    browser.close();
  }
}
