// Where windows.move took a window from, so windows.moveBack can put it back
// exactly: same workspace, and the same floating frame or tiled state.
// Kept in memory; a host restart forgets pending returns.

import type { Window } from "./desktop.ts";
import type * as hypr from "./hyprland.ts";
import type { Rect } from "./placement.ts";

export interface Origin {
  workspace: number;
  floating: boolean;
  frame: Rect;
  movedAt: number;
}

const origins = new Map<number, Origin>();

/** Remember where a window started. The first move wins until it is moved back. */
export function record(window: Window) {
  if (origins.has(window.wid)) return;
  const workspace = window.spaceIds[0];
  if (workspace === undefined) return;
  origins.set(window.wid, { workspace, floating: window.isFloating, frame: { ...window.frame }, movedAt: Date.now() });
}

export const get = (wid: number) => origins.get(wid);
export const forget = (wid: number) => origins.delete(wid);
export const clear = () => origins.clear();

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
