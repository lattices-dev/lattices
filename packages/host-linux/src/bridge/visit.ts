import * as hypr from "../hyprland.ts";
import * as input from "../input.ts";
import { realMonitors, type Monitor } from "../cursor-home.ts";
import { PointerSession, type Button, type Extent } from "../wayland.ts";

export type Edge = "left" | "right" | "top" | "bottom";
export type VisitUp =
  | { t: "enter"; name: string; edge: Edge; at: number }
  | { t: "move" | "scroll"; dx: number; dy: number }
  | { t: "button"; button: Button; down: boolean }
  | { t: "key"; key: string; mods: string[] }
  | { t: "text"; text: string }
  | { t: "ping" | "leave" };
export type VisitDown =
  | { t: "ready"; x: number; y: number }
  | { t: "exit"; edge: Edge; at: number }
  | { t: "pong" }
  | { t: "error"; message: string };
export interface Point { x: number; y: number }
export interface VisitScreen extends Extent { name: string }
export interface VisitorState extends Point { visible: boolean; name: string; screens: VisitScreen[] }
export interface VisitorOverlay {
  onFailure?: (error: Error) => void;
  show(state: VisitorState): Promise<void>;
  update(state: VisitorState): void;
  hide(): void;
  stop(): Promise<void>;
}

const edges: Edge[] = ["left", "right", "top", "bottom"];
const finite = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n);
const delta = (n: unknown) => finite(n) && Math.abs(n) <= 1_000_000;

/** Reject malformed messages before they can change desktop state. */
export function parseVisitMessage(value: unknown): VisitUp {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid visit message");
  const v = value as Record<string, unknown>;
  switch (v.t) {
    case "enter":
      if (typeof v.name === "string" && v.name.trim() && v.name.length <= 64 && !/[\x00-\x1f\x7f]/.test(v.name)
        && edges.includes(v.edge as Edge) && finite(v.at) && v.at >= 0 && v.at <= 1) return v as VisitUp;
      break;
    case "move": case "scroll":
      if (delta(v.dx) && delta(v.dy)) return v as VisitUp;
      break;
    case "button":
      if (["left", "right", "middle"].includes(v.button as string) && typeof v.down === "boolean") return v as VisitUp;
      break;
    case "key":
      if (typeof v.key === "string" && /^[A-Za-z0-9_]{1,128}$/.test(v.key) && Array.isArray(v.mods) && v.mods.length <= 4
        && v.mods.every((m) => ["ctrl", "shift", "alt", "super"].includes(m)) && new Set(v.mods).size === v.mods.length) return v as VisitUp;
      break;
    case "text":
      if (typeof v.text === "string" && Buffer.byteLength(v.text) <= 200_000 && !v.text.includes("\0")) return v as VisitUp;
      break;
    case "ping": case "leave": return v as VisitUp;
  }
  throw new Error("Invalid visit message");
}

export function screenFor(m: Monitor): VisitScreen {
  const rotated = m.transform % 2 === 1;
  return { name: m.name, x: m.x, y: m.y, w: (rotated ? m.height : m.width) / m.scale, h: (rotated ? m.width : m.height) / m.scale };
}

export function extentFor(screens: Extent[]): Extent {
  if (!screens.length) throw new Error("No real monitor available");
  const x = Math.min(...screens.map((s) => s.x));
  const y = Math.min(...screens.map((s) => s.y));
  return { x, y, w: Math.max(...screens.map((s) => s.x + s.w)) - x, h: Math.max(...screens.map((s) => s.y + s.h)) - y };
}

const clamp = (n: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, n));

/** Project gaps in a staggered layout onto the nearest actual screen. */
export function clampToScreens(point: Point, screens: VisitScreen[]): Point {
  let best: Point | undefined;
  let distance = Infinity;
  for (const s of screens) {
    const candidate = { x: clamp(point.x, s.x, s.x + s.w - 1), y: clamp(point.y, s.y, s.y + s.h - 1) };
    const d = (point.x - candidate.x) ** 2 + (point.y - candidate.y) ** 2;
    if (d < distance) { best = candidate; distance = d; }
  }
  if (!best) throw new Error("No real monitor available");
  return best;
}

export class VisitArea {
  readonly screens: VisitScreen[];
  readonly extent: Extent;
  constructor(monitors: Monitor[]) {
    this.screens = realMonitors(monitors).map(screenFor);
    this.extent = extentFor(this.screens);
  }

  enter(edge: Edge, at: number): Point {
    const e = this.extent;
    // Choose a screen on that outer edge, even when the bounding edge has a gap.
    const boundary = this.screens.filter((s) => edge === "left" ? s.x === e.x : edge === "right" ? s.x + s.w === e.x + e.w
      : edge === "top" ? s.y === e.y : s.y + s.h === e.y + e.h);
    return clampToScreens({ x: edge === "left" ? e.x : edge === "right" ? e.x + e.w - 1 : e.x + at * (e.w - 1),
      y: edge === "top" ? e.y : edge === "bottom" ? e.y + e.h - 1 : e.y + at * (e.h - 1) }, boundary);
  }

  exitAt(edge: Edge, point: Point): number | null {
    const e = this.extent;
    const outside = edge === "left" ? point.x < e.x : edge === "right" ? point.x > e.x + e.w - 1
      : edge === "top" ? point.y < e.y : point.y > e.y + e.h - 1;
    if (!outside) return null;
    return edge === "left" || edge === "right" ? clamp((point.y - e.y) / Math.max(1, e.h - 1), 0, 1)
      : clamp((point.x - e.x) / Math.max(1, e.w - 1), 0, 1);
  }
}

export interface VisitPointer {
  move(x: number, y: number, extent: Extent): Promise<void>;
  button(button: Button, down: boolean): Promise<void>;
  scroll(dx: number, dy: number): Promise<void>;
  close(): Promise<void>;
}
export interface VisitDependencies {
  monitors(): Promise<Monitor[]>;
  cursor(): Promise<Point>;
  pointer(): Promise<VisitPointer>;
  restore(point: Point): Promise<void>;
  key(key: string, mods: string[]): Promise<unknown>;
  text(text: string): Promise<unknown>;
  log(message: string): void;
}
export const visitDependencies: VisitDependencies = {
  monitors: hypr.monitors, cursor: hypr.cursorPos, pointer: () => PointerSession.open(),
  restore: (p) => hypr.warpCursor(p.x, p.y), key: input.pressKeysym, text: input.typeText,
  log: (message) => console.error(`[lattices-visit] ${message}`),
};

/** Calls are serialized by the channel, including teardown on socket loss. */
export class VisitSession {
  private pointer: VisitPointer | null = null;
  private home: Point | null = null;
  private pointerExtent!: Extent;
  private area!: VisitArea;
  private point!: Point;
  private edge!: Edge;
  private name = "";
  private held = new Set<Button>();
  constructor(private overlay: VisitorOverlay, private deps = visitDependencies) {}

  private state(): VisitorState { return { visible: true, name: this.name, ...this.point, screens: this.area.screens }; }

  async enter(message: Extract<VisitUp, { t: "enter" }>): Promise<VisitDown> {
    if (this.pointer) throw new Error("Visit already entered");
    const monitors = await this.deps.monitors();
    this.area = new VisitArea(monitors);
    // Absolute virtual-pointer motion maps onto ALL compositor outputs,
    // including virtual outputs. Only the visitor's movement excludes them.
    this.pointerExtent = extentFor(monitors.filter((m) => !m.disabled && (!m.mirrorOf || m.mirrorOf === "none")).map(screenFor));
    this.home = await this.deps.cursor();
    this.edge = message.edge;
    this.name = message.name.trim().slice(0, 24);
    this.point = this.area.enter(message.edge, message.at);
    try {
      this.pointer = await this.deps.pointer();
      await this.overlay.show(this.state());
    } catch (error) {
      await this.end();
      throw error;
    }
    return { t: "ready", ...this.point };
  }

  async perform(message: Exclude<VisitUp, { t: "enter" }>): Promise<VisitDown | null> {
    if (!this.pointer) throw new Error("Enter a visit first");
    switch (message.t) {
      case "move": {
        const proposed = { x: this.point.x + message.dx, y: this.point.y + message.dy };
        const at = this.area.exitAt(this.edge, proposed);
        if (at !== null) {
          await this.end();
          return { t: "exit", edge: this.edge, at };
        }
        this.point = clampToScreens(proposed, this.area.screens);
        this.overlay.update(this.state());
        if (this.held.size) await this.land();
        break;
      }
      case "button":
        await this.land();
        // Record before awaiting input: teardown still releases a press whose
        // compositor roundtrip failed after it was written to the connection.
        if (message.down) this.held.add(message.button);
        await this.pointer.button(message.button, message.down);
        if (!message.down) this.held.delete(message.button);
        break;
      case "scroll": await this.land(); await this.pointer.scroll(message.dx, message.dy); break;
      case "key": await this.deps.key(message.key, message.mods); break;
      case "text": await this.deps.text(message.text); break;
      case "leave": await this.end(); break;
      case "ping": return { t: "pong" };
    }
    return null;
  }

  private async land() {
    await this.pointer!.move(this.point.x, this.point.y, this.pointerExtent);
    // follow_mouse=1: warping home here would focus the host's old window.
    // Keep the real pointer at the click/scroll; ordinary moves are overlay-only.
  }

  async end(): Promise<void> {
    const pointer = this.pointer;
    this.pointer = null;
    if (!pointer) return;
    this.overlay.hide();
    const recover = async (operation: () => Promise<void>) => {
      try { await operation(); } catch (error) { this.deps.log(`cleanup: ${String(error)}`); }
    };
    for (const button of this.held) await recover(() => pointer.button(button, false));
    this.held.clear();
    // Always restore the captured location, even if the host moved during a visit.
    if (this.home) {
      try { await pointer.move(this.home.x, this.home.y, this.pointerExtent); }
      catch { await recover(() => this.deps.restore(this.home!)); }
    }
    await recover(() => pointer.close());
    this.home = null;
  }
}
