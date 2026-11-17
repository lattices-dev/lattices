// Where windows.move took a window from, so windows.moveBack can put it back
// exactly: same workspace, and the same floating frame or tiled state.
// Once loaded, kept in ~/.lattices/host-moves.json so a pending return
// survives a host restart (wids follow Hyprland addresses, which outlive us).

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { Window } from "./desktop.ts";
import type * as hypr from "./hyprland.ts";
import type { Rect } from "./placement.ts";

export interface Origin {
  workspace: number;
  floating: boolean;
  frame: Rect;
  movedAt: number;
}

export const STORE_PATH = join(homedir(), ".lattices", "host-moves.json");

const origins = new Map<number, Origin>();
let store: string | null = null;

/** Restore pending returns from `path` and keep it current from now on. */
export function load(path = STORE_PATH) {
  store = path;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as Record<string, Origin>;
    for (const [wid, origin] of Object.entries(parsed)) {
      if (Number.isFinite(Number(wid)) && typeof origin?.workspace === "number") origins.set(Number(wid), origin);
    }
  } catch {}
}

function save() {
  if (!store) return;
  try {
    mkdirSync(dirname(store), { recursive: true });
    const temporary = store + ".tmp";
    writeFileSync(temporary, JSON.stringify(Object.fromEntries(origins), null, 2) + "\n");
    renameSync(temporary, store);
  } catch (error) {
    console.error(`moves: could not save ${store}: ${(error as Error).message}`);
  }
}

/** Remember where a window started. The first move wins until it is moved back. */
export function record(window: Window) {
  if (origins.has(window.wid)) return;
  const workspace = window.spaceIds[0];
  if (workspace === undefined) return;
  origins.set(window.wid, { workspace, floating: window.isFloating, frame: { ...window.frame }, movedAt: Date.now() });
  save();
}

export const get = (wid: number) => origins.get(wid);
export function forget(wid: number) {
  if (origins.delete(wid)) save();
}
/** Forgets everything and stops persisting; for tests. */
export function clear() {
  origins.clear();
  store = null;
}

/** The operations that return `window` to `origin`. */
export function returnOps(window: Window, origin: Origin): hypr.Op[] {
  const address = window.address;
  const ops: hypr.Op[] = [];
  if (!window.spaceIds.includes(origin.workspace)) ops.push({ op: "toWorkspace", address, workspace: origin.workspace });
  if (origin.floating) {
    if (!window.isFloating) ops.push({ op: "float", address });
    const f = window.frame;
    const o = origin.frame;
    if (f.w !== o.w || f.h !== o.h) ops.push({ op: "resize", address, w: o.w, h: o.h });
    if (f.x !== o.x || f.y !== o.y || f.w !== o.w || f.h !== o.h) ops.push({ op: "move", address, x: o.x, y: o.y });
  } else if (window.isFloating) {
    ops.push({ op: "tile", address });
  }
  return ops;
}
