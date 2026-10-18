// Hyprland state projected onto the Mac daemon's shapes (docs/api.md:
// windows.list, spaces.list), so clients read both hosts the same way.

import * as hypr from "./hyprland.ts";
import type { Fractions, Rect } from "./placement.ts";
import { rectFor } from "./placement.ts";
import { RouterError, num, str, type Json, type Params } from "./router.ts";

export interface Window {
  wid: number;
  address: string;
  app: string;
  pid: number;
  title: string;
  frame: Rect;
  spaceIds: number[];
  displayIndex: number;
  isOnScreen: boolean;
  isFloating: boolean;
  isFullscreen: boolean;
  isFocused: boolean;
  latticesSession?: string;
}

export interface Display {
  displayIndex: number;
  displayId: string;
  name: string;
  frame: Rect;
  visibleFrame: Rect;
  scale: number;
  /** A headless output: no panel behind it, only captures and remote views see it. */
  virtual: boolean;
  currentSpaceId: number;
  spaces: { id: number; index: number; name: string; display: number; isCurrent: boolean; windowCount: number }[];
}

/**
 * A stable uint32 id for a window. Hyprland's stableId is hex and survives
 * address reuse; the low 32 bits of the address are the fallback.
 */
export function widFor(client: Pick<hypr.HyprClient, "address" | "stableId">): number {
  if (client.stableId && /^[0-9a-f]+$/i.test(client.stableId)) {
    const id = Number.parseInt(client.stableId, 16);
    if (id > 0 && id <= 0xffffffff) return id;
  }
  return Number(BigInt(client.address) & 0xffffffffn);
}

const SESSION_TAG = /\[lattices:([^\]]+)\]/;

export function displayIndexById(monitors: hypr.HyprMonitor[]): Map<number, number> {
  const sorted = [...monitors].sort((a, b) => a.x - b.x || a.y - b.y || a.id - b.id);
  return new Map(sorted.map((m, index) => [m.id, index]));
}

export function toWindow(
  client: hypr.HyprClient,
  monitors: hypr.HyprMonitor[],
  focusedAddress: string | null
): Window {
  const index = displayIndexById(monitors);
  const visibleWorkspaces = new Set(monitors.map((m) => m.activeWorkspace.id));
  const session = SESSION_TAG.exec(client.title)?.[1];
  return {
    wid: widFor(client),
    address: client.address,
    app: client.class || "unknown",
    pid: client.pid,
    title: client.title,
    frame: { x: client.at[0], y: client.at[1], w: client.size[0], h: client.size[1] },
    spaceIds: [client.workspace.id],
    displayIndex: index.get(client.monitor) ?? 0,
    isOnScreen: !client.hidden && client.mapped && (client.pinned || visibleWorkspaces.has(client.workspace.id)),
    isFloating: client.floating,
    isFullscreen: client.fullscreen > 0,
    isFocused: client.address === focusedAddress,
    ...(session ? { latticesSession: session } : {}),
  };
}

/** Headless outputs report no make, model or serial; real panels report EDID. */
export function isVirtual(m: Pick<hypr.HyprMonitor, "make" | "model" | "serial">): boolean {
  return !m.make && !m.model && !m.serial;
}

export function toDisplays(monitors: hypr.HyprMonitor[], workspaces: hypr.HyprWorkspace[]): Display[] {
  const index = displayIndexById(monitors);
  return [...monitors]
    .sort((a, b) => (index.get(a.id) ?? 0) - (index.get(b.id) ?? 0))
    .map((m) => {
      const displayIndex = index.get(m.id) ?? 0;
      // Hyprland reports monitor size in physical pixels; windows use logical.
      const w = Math.round(m.width / m.scale);
      const h = Math.round(m.height / m.scale);
      const [left, top, right, bottom] = m.reserved;
      const spaces = workspaces
        .filter((ws) => ws.monitorID === m.id && ws.id > 0)
        .sort((a, b) => a.id - b.id)
        .map((ws, i) => ({
          id: ws.id,
          index: i + 1,
          name: ws.name,
          display: displayIndex,
          isCurrent: ws.id === m.activeWorkspace.id,
          windowCount: ws.windows,
        }));
      return {
        displayIndex,
        displayId: m.name,
        name: m.description || m.name,
        frame: { x: m.x, y: m.y, w, h },
        visibleFrame: { x: m.x + left, y: m.y + top, w: w - left - right, h: h - top - bottom },
        scale: m.scale,
        virtual: isVirtual(m),
        currentSpaceId: m.activeWorkspace.id,
        spaces,
      };
    });
}

export async function snapshot() {
  const [clients, monitors, workspaces, active] = await Promise.all([
    hypr.clients(),
    hypr.monitors(),
    hypr.workspaces(),
    hypr.activeWindow(),
  ]);
  const focused = active?.address ?? null;
  const windows = clients
    .filter((c) => c.mapped && c.workspace.id > 0)
    .sort((a, b) => a.focusHistoryID - b.focusHistoryID)
    .map((c) => toWindow(c, monitors, focused));
  return { windows, displays: toDisplays(monitors, workspaces), clients, monitors, focused };
}

/**
 * Resolve a target the way the Mac does: wid -> session -> app/title ->
 * frontmost. Returns the window and the raw Hyprland client.
 */
export async function resolveTarget(params: Params) {
  const snap = await snapshot();
  const wid = num(params, "wid");
  const session = str(params, "session");
  const app = str(params, "app")?.toLowerCase();
  const title = str(params, "title")?.toLowerCase();

  let window: Window | undefined;
  if (wid !== undefined) {
    window = snap.windows.find((w) => w.wid === wid);
    if (!window) throw RouterError.notFound(`window ${wid}`);
  } else if (session) {
    window = snap.windows.find((w) => w.latticesSession === session);
    if (!window) throw RouterError.notFound(`session window ${session}`);
  } else if (app) {
    window = snap.windows.find(
      (w) => w.app.toLowerCase().includes(app) && (!title || w.title.toLowerCase().includes(title))
    );
    if (!window) throw RouterError.notFound(`window for app ${app}`);
  } else {
    window = snap.windows.find((w) => w.isFocused) ?? snap.windows[0];
    if (!window) throw RouterError.notFound("frontmost window");
  }
  return { window, snap };
}

export function searchWindows(windows: Window[], query: string, limit = 50): Json[] {
  const q = query.toLowerCase();
  const scored: { window: Window; score: number; matchSource: string }[] = [];
  for (const window of windows) {
    let score = 0;
    let matchSource = "";
    if (window.title.toLowerCase().includes(q)) {
      score += 3;
      matchSource ||= "title";
    }
    if (window.latticesSession?.toLowerCase().includes(q)) {
      score += 3;
      matchSource ||= "session";
    }
    if (window.app.toLowerCase().includes(q)) {
      score += 2;
      matchSource ||= "app";
    }
    if (score > 0) scored.push({ window, score, matchSource });
  }
  return scored
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map(({ window, score, matchSource }) => ({ ...window, score, matchSource }) as unknown as Json);
}

/** Move and resize a window to fractions of a display's visible frame. */
export async function place(window: Window, fractions: Fractions, display: Display, dryRun = false) {
  const target = rectFor(fractions, display.visibleFrame);
  const address = window.address;
  const ops: hypr.Op[] = [];
  if (window.isFullscreen) ops.push({ op: "unfullscreen", address });
  // A tiled window ignores exact geometry; float it so the frame sticks.
  if (!window.isFloating) ops.push({ op: "float", address });
  // Resize first: Hyprland resizes around the center, then the move pins the origin.
  ops.push({ op: "resize", address, w: target.w, h: target.h });
  ops.push({ op: "move", address, x: target.x, y: target.y });
  const commands = dryRun ? await hypr.plan(ops) : await hypr.apply(ops);
  return { target, commands };
}
