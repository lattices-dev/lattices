// computer.acted: one event per executed computer.* action, so a viewer can
// draw where the host just clicked, typed or scrolled on top of its still.
// Points are global logical pixels, like every other host coordinate; each
// event also carries the display it landed on and the point as a ratio of
// that display, which is what an overlay on a capture.still needs.

import type { Display } from "./desktop.ts";

export interface Point {
  x: number;
  y: number;
}

export interface Action {
  kind: "click" | "doubleClick" | "rightClick" | "drag" | "scroll" | "aim" | "typeText" | "pressKey" | "hotkey";
  label: string;
  point?: Point | null;
  to?: Point | null;
  wid?: number | null;
  /** An accessibility element, once ax.* exists on this host. */
  element?: { role?: string; name?: string; frame?: { x: number; y: number; w: number; h: number } } | null;
}

export interface ActedEvent extends Action {
  point: Point | null;
  to: Point | null;
  wid: number | null;
  element: Action["element"];
  displayIndex: number | null;
  /** The point relative to its display's frame, 0-1. */
  ratio: Point | null;
  toRatio: Point | null;
  at: number;
}

export function displayAt(displays: Display[], p: Point): Display | undefined {
  return displays.find((d) => p.x >= d.frame.x && p.x < d.frame.x + d.frame.w && p.y >= d.frame.y && p.y < d.frame.y + d.frame.h);
}

const round = (n: number) => Math.round(n * 10_000) / 10_000;
const ratioIn = (d: Display | undefined, p: Point | null) =>
  d && p ? { x: round((p.x - d.frame.x) / d.frame.w), y: round((p.y - d.frame.y) / d.frame.h) } : null;

/**
 * Place an action on a display. Pointer actions use their point; keyboard
 * actions fall back to `fallbackDisplay` (the target or focused window's).
 */
export function toEvent(action: Action, displays: Display[], fallbackDisplay?: number, now = Date.now()): ActedEvent {
  const point = action.point ? { x: Math.round(action.point.x), y: Math.round(action.point.y) } : null;
  const to = action.to ? { x: Math.round(action.to.x), y: Math.round(action.to.y) } : null;
  const display = point ? displayAt(displays, point) : displays.find((d) => d.displayIndex === fallbackDisplay);
  return {
    ...action,
    point,
    to,
    wid: action.wid ?? null,
    element: action.element ?? null,
    displayIndex: display?.displayIndex ?? null,
    ratio: ratioIn(display, point),
    toRatio: ratioIn(display, to),
    at: now,
  };
}

/** A label that never repeats typed text, which may be a secret. */
export function typeLabel(length: number, enter: boolean): string {
  return `Type ${length} char${length === 1 ? "" : "s"}${enter ? " + Enter" : ""}`;
}

export function keyLabel(key: string, modifiers: string[], count: number): string {
  const combo = [...modifiers, key].join("+");
  return count > 1 ? `${combo} ×${count}` : combo;
}
