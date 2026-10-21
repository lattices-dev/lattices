// Hyprland over its command and event sockets, outside the compositor.

import { commandSocketPath, dispatchBatch, request } from "./hyprland-command.ts";
import { initialEventHealth, subscribeEvents } from "./hyprland-events.ts";

export interface HyprClient {
  address: string;
  mapped: boolean;
  hidden: boolean;
  at: [number, number];
  size: [number, number];
  workspace: { id: number; name: string };
  floating: boolean;
  monitor: number;
  class: string;
  title: string;
  pid: number;
  xwayland: boolean;
  pinned: boolean;
  fullscreen: number;
  focusHistoryID: number;
  stableId?: string;
}

export interface HyprMonitor {
  id: number;
  name: string;
  description: string;
  /** Empty on headless (virtual) outputs. */
  make?: string;
  model?: string;
  serial?: string;
  x: number;
  y: number;
  width: number;
  height: number;
  scale: number;
  transform: number;
  /** Space taken by bars: [left, top, right, bottom], in logical pixels. */
  reserved: [number, number, number, number];
  activeWorkspace: { id: number; name: string };
  focused: boolean;
}

export interface HyprWorkspace {
  id: number;
  name: string;
  monitor: string;
  monitorID: number;
  windows: number;
}

export async function hyprctlJson<T>(command: string): Promise<T> {
  const out = await request("j/" + command);
  return JSON.parse(out) as T;
}

// Hyprland 0.55 moved dispatchers to Lua: `hyprctl dispatch 'hl.dsp.focus({...})'`.
// Older versions take `hyprctl dispatch focuswindow address:...`. The dialect
// is detected once with a no-op and every operation is spelled for it.
let luaDialect: { path: string; value: Promise<boolean> } | null = null;

export function usesLua(): Promise<boolean> {
  const path = commandSocketPath();
  if (!luaDialect || luaDialect.path !== path) {
    const value = request("/dispatch hl.dsp.no_op()", { path })
      .then((out) => out.trim() === "ok")
      .catch((error) => { luaDialect = null; throw error; });
    luaDialect = { path, value };
  }
  return luaDialect.value;
}

export type Op =
  | { op: "focus"; address: string }
  | { op: "float"; address: string }
  | { op: "tile"; address: string }
  | { op: "resize"; address: string; w: number; h: number }
  | { op: "move"; address: string; x: number; y: number }
  | { op: "toWorkspace"; address: string; workspace: number | string }
  | { op: "unfullscreen"; address: string }
  | { op: "close"; address: string }
  | { op: "focusWorkspace"; workspace: number | "e+1" | "e-1" | "previous" }
  | { op: "focusMonitor"; monitor: string };

const luaString = (value: string) => JSON.stringify(value);
const int = (n: number) => String(Math.round(n));
const workspace = (value: number | string, lua: boolean) => typeof value === "number" ? int(value) : lua ? luaString(value) : value;

export function spell(op: Op, lua: boolean): string {
  if (op.op === "focusWorkspace") return lua ? `hl.dsp.focus({ workspace = ${workspace(op.workspace, true)} })` : `workspace ${workspace(op.workspace, false)}`;
  if (op.op === "focusMonitor") return lua ? `hl.dsp.focus({ monitor = ${luaString(op.monitor)} })` : `focusmonitor ${op.monitor}`;
  const win = `address:${op.address}`;
  if (lua) {
    const w = `window = ${luaString(win)}`;
    switch (op.op) {
      case "focus":
        return `hl.dsp.focus({ ${w} })`;
      case "float":
        return `hl.dsp.window.float({ action = "enable", ${w} })`;
      case "tile":
        return `hl.dsp.window.float({ action = "disable", ${w} })`;
      case "resize":
        return `hl.dsp.window.resize({ x = ${int(op.w)}, y = ${int(op.h)}, ${w} })`;
      case "move":
        return `hl.dsp.window.move({ x = ${int(op.x)}, y = ${int(op.y)}, ${w} })`;
      case "toWorkspace":
        return `hl.dsp.window.move({ workspace = ${workspace(op.workspace, true)}, follow = false, ${w} })`;
      case "unfullscreen":
        return `hl.dsp.window.fullscreen({ action = "unset", ${w} })`;
      case "close":
        return `hl.dsp.window.close({ ${w} })`;
    }
  }
  switch (op.op) {
    case "focus":
      return `focuswindow ${win}`;
    case "float":
      return `setfloating ${win}`;
    case "tile":
      return `settiled ${win}`;
    case "resize":
      return `resizewindowpixel exact ${int(op.w)} ${int(op.h)},${win}`;
    case "move":
      return `movewindowpixel exact ${int(op.x)} ${int(op.y)},${win}`;
    case "toWorkspace":
      return `movetoworkspacesilent ${workspace(op.workspace, false)},${win}`;
    case "unfullscreen":
      return `fullscreenstate 0 0,${win}`;
    case "close":
      return `closewindow ${win}`;
  }
}

/** Run operations in one command-socket batch; throws if any fails. */
export async function apply(ops: Op[]): Promise<string[]> {
  if (ops.length === 0) return [];
  const lua = await usesLua();
  const commands = ops.map((op) => spell(op, lua));
  await dispatchBatch(commands);
  return commands;
}

/** The commands `apply` would run, for dry runs and receipts. */
export async function plan(ops: Op[]): Promise<string[]> {
  const lua = await usesLua();
  return ops.map((op) => spell(op, lua));
}

/** Launch a command through the compositor, so it inherits the session. */
export async function exec(command: string): Promise<void> {
  const lua = await usesLua();
  const spelled = lua ? `hl.dsp.exec_cmd(${JSON.stringify(command)})` : `exec ${command}`;
  const out = (await request("/dispatch " + spelled)).trim();
  if (out !== "ok") throw new Error(`hyprctl: ${out}`);
}

export const clients = () => hyprctlJson<HyprClient[]>("clients");
export const monitors = () => hyprctlJson<HyprMonitor[]>("monitors");
export const workspaces = () => hyprctlJson<HyprWorkspace[]>("workspaces");
export const activeWindow = async () => {
  const w = await hyprctlJson<Partial<HyprClient>>("activewindow");
  return w.address ? (w as HyprClient) : null;
};
export const cursorPos = () => hyprctlJson<{ x: number; y: number }>("cursorpos");

/** Recovery path if the visit's Wayland pointer connection has failed. */
export async function warpCursor(x: number, y: number): Promise<void> {
  const command = await usesLua()
    ? `hl.dsp.cursor.move({ x = ${int(x)}, y = ${int(y)} })`
    : `movecursor ${int(x)} ${int(y)}`;
  const out = (await request("/dispatch " + command, { timeoutMs: 1500 })).trim();
  if (out !== "ok") throw new Error(`hyprctl: ${out}`);
}

export function available(): boolean {
  return Boolean(process.env.HYPRLAND_INSTANCE_SIGNATURE);
}

let eventStream: ReturnType<typeof subscribeEvents> | null = null;

export const getEventStreamHealth = () => eventStream?.health() ?? initialEventHealth();

/** The existing stop-function API, with a ready promise for startup/describe. */
export function onEvents(
  listener: (event: string, data: string) => void,
  options: Parameters<typeof subscribeEvents>[1] = {}
): (() => void) & { ready: Promise<void> } {
  eventStream?.stop();
  eventStream = subscribeEvents(listener, options);
  return Object.assign(eventStream.stop, { ready: eventStream.ready });
}
