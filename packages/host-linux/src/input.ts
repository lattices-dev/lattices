// Keyboard through wtype (the Wayland virtual keyboard protocol) and pointer
// through the virtual pointer protocol (wayland.ts).

import { run } from "./exec.ts";
import type { Display } from "./desktop.ts";
import { runPointer, type Button, type Extent, type PointerStep } from "./wayland.ts";

// Mac clients say `command`; on Linux the shortcut a Mac user means by
// command+c is ctrl+c. `super`/`logo` reach the compositor's own modifier.
const MODIFIERS: Record<string, string> = {
  command: "ctrl",
  cmd: "ctrl",
  control: "ctrl",
  ctrl: "ctrl",
  option: "alt",
  opt: "alt",
  alt: "alt",
  shift: "shift",
  super: "logo",
  logo: "logo",
  meta: "logo",
  win: "logo",
};

const KEYS: Record<string, string> = {
  escape: "Escape",
  esc: "Escape",
  enter: "Return",
  return: "Return",
  tab: "Tab",
  space: "space",
  backspace: "BackSpace",
  delete: "BackSpace",
  forwarddelete: "Delete",
  up: "Up",
  down: "Down",
  left: "Left",
  right: "Right",
  home: "Home",
  end: "End",
  pageup: "Prior",
  pagedown: "Next",
  ",": "comma",
  ".": "period",
  "/": "slash",
  ";": "semicolon",
  "'": "apostrophe",
  "[": "bracketleft",
  "]": "bracketright",
  "\\": "backslash",
  "-": "minus",
  "=": "equal",
  "+": "plus",
  "_": "underscore",
  "`": "grave",
};

export function keysym(key: string): string {
  const lower = key.toLowerCase();
  if (KEYS[lower]) return KEYS[lower];
  if (/^f([1-9]|1[0-9]|2[0-4])$/.test(lower)) return lower.toUpperCase();
  if (/^[a-z0-9]$/.test(lower)) return lower;
  if (key.length > 1) return key; // already a keysym name, e.g. XF86AudioPlay
  throw new Error(`Unknown key: ${key}`);
}

export function parseShortcut(shortcut: string): { modifiers: string[]; key: string } {
  const parts = shortcut.split("+").map((p) => p.trim()).filter(Boolean);
  const key = parts.pop();
  if (!key) throw new Error(`Empty shortcut: ${shortcut}`);
  return { modifiers: parts, key };
}

/** wtype arguments that press `key` with `modifiers` held, `count` times. */
function strokeArgs(symbol: string, modifiers: string[], count: number, delayMs: number): string[] {
  const mods = modifiers.map((m) => {
    const mapped = MODIFIERS[m.toLowerCase()];
    if (!mapped) throw new Error(`Unknown modifier: ${m}`);
    return mapped;
  });
  const args: string[] = [];
  for (let i = 0; i < count; i++) {
    if (i > 0) args.push("-s", String(Math.round(delayMs)));
    for (const m of mods) args.push("-M", m);
    args.push("-k", symbol);
    for (const m of [...mods].reverse()) args.push("-m", m);
  }
  return args;
}

export function wtypeKeyArgs(key: string, modifiers: string[] = [], count = 1, delayMs = 80): string[] {
  return strokeArgs(keysym(key), modifiers, count, delayMs);
}

/** Visits already speak XKB: preserve A vs a, and Delete vs BackSpace. */
export function wtypeKeysymArgs(key: string, modifiers: string[] = []): string[] {
  return strokeArgs(key, modifiers, 1, 80);
}

export async function pressKeysym(key: string, modifiers: string[] = []) {
  await run("wtype", wtypeKeysymArgs(key, modifiers));
}

export async function typeText(text: string, enter = false) {
  if (text) await run("wtype", ["--", text]);
  if (enter) await run("wtype", ["-k", "Return"]);
}

export async function pressKey(key: string, modifiers: string[] = [], count = 1, delayMs = 80) {
  await run("wtype", wtypeKeyArgs(key, modifiers, count, delayMs));
}

/** The bounding box of every display, which absolute pointer motion maps onto. */
export function layoutExtent(displays: Display[]): Extent {
  const x = Math.min(...displays.map((d) => d.frame.x));
  const y = Math.min(...displays.map((d) => d.frame.y));
  const right = Math.max(...displays.map((d) => d.frame.x + d.frame.w));
  const bottom = Math.max(...displays.map((d) => d.frame.y + d.frame.h));
  return { x, y, w: right - x, h: bottom - y };
}

export async function click(x: number, y: number, extent: Extent, button: Button = "left", count = 1, delayMs = 80) {
  const steps: PointerStep[] = [{ kind: "move", x, y }];
  for (let i = 0; i < count; i++) {
    if (i > 0) steps.push({ kind: "wait", ms: delayMs });
    steps.push({ kind: "down", button }, { kind: "up", button });
  }
  await runPointer(steps, extent);
}

export async function drag(
  from: { x: number; y: number },
  to: { x: number; y: number },
  extent: Extent,
  button: Button = "left",
  steps = 12
) {
  const path: PointerStep[] = [{ kind: "move", ...from }, { kind: "down", button }, { kind: "wait", ms: 30 }];
  for (let i = 1; i <= steps; i++) {
    path.push({ kind: "move", x: from.x + ((to.x - from.x) * i) / steps, y: from.y + ((to.y - from.y) * i) / steps });
    path.push({ kind: "wait", ms: 10 });
  }
  path.push({ kind: "up", button });
  await runPointer(path, extent);
}

export async function scroll(x: number | undefined, y: number | undefined, dx: number, dy: number, extent: Extent) {
  const steps: PointerStep[] = [];
  if (x !== undefined && y !== undefined) steps.push({ kind: "move", x, y });
  steps.push({ kind: "scroll", dx, dy });
  await runPointer(steps, extent);
}

export async function moveCursor(x: number, y: number, extent: Extent) {
  await runPointer([{ kind: "move", x, y }], extent);
}
