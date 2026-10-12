import { run } from "./exec.ts";
import type { HyprMonitor } from "./hyprland.ts";

export type Monitor = HyprMonitor & { disabled?: boolean; mirrorOf?: string; physicalWidth?: number; physicalHeight?: number };

/** The physical desktop shared by Bring Cursor Home and visiting cursors. */
export function realMonitors(monitors: Monitor[]): Monitor[] {
  return monitors.filter((m) => !m.disabled && (!m.mirrorOf || m.mirrorOf === "none")
    && !/^(LATS(?:-|$)|HEADLESS|WL-|VIRTUAL|Virtual-|RDP-)/i.test(m.name)
    && !/headless|virtual output/i.test(m.description)
    && !(m.physicalWidth === 0 && m.physicalHeight === 0 && !m.description)
    && Number.isFinite(m.x) && Number.isFinite(m.y) && Number.isFinite(m.width) && Number.isFinite(m.height)
    && Number.isFinite(m.scale) && m.width > 0 && m.height > 0 && m.scale > 0);
}

export function pickHomeMonitor(monitors: Monitor[]): Monitor {
  const real = realMonitors(monitors);
  const monitor = real.find((m) => m.focused) ?? real[0];
  if (!monitor) throw new Error("No real monitor available");
  return monitor;
}

export function monitorCentre(monitor: HyprMonitor): { x: number; y: number } {
  const rotated = monitor.transform % 2 === 1;
  return {
    x: Math.round(monitor.x + (rotated ? monitor.height : monitor.width) / monitor.scale / 2),
    y: Math.round(monitor.y + (rotated ? monitor.width : monitor.height) / monitor.scale / 2),
  };
}

export interface CursorHomeDependencies { run: typeof run }

export async function bringCursorHome(deps: CursorHomeDependencies = { run }) {
  const monitors = JSON.parse(await deps.run("hyprctl", ["monitors", "-j"], { timeoutMs: 1500 })) as Monitor[];
  const monitor = pickHomeMonitor(monitors);
  const point = monitorCentre(monitor);
  let response = await deps.run("hyprctl", ["dispatch", "movecursor", String(point.x), String(point.y)], { timeoutMs: 1500 }).catch(() => "");
  // Hyprland 0.55+ uses Lua dispatchers. Support both without shell execution.
  if (response.trim() !== "ok") {
    response = await deps.run("hyprctl", ["dispatch", `hl.dsp.cursor.move({ x = ${point.x}, y = ${point.y} })`], { timeoutMs: 1500 });
  }
  if (response.trim() !== "ok") throw new Error(`hyprctl: ${response.trim()}`);
  return { ok: true, monitor: monitor.name, ...point };
}
