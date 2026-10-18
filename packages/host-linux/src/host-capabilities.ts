import * as desktop from "./desktop.ts";
import { hasCommand } from "./exec.ts";
import * as hypr from "./hyprland.ts";
import type { EventStreamHealth } from "./hyprland-events.ts";
import { waylandGlobals } from "./wayland.ts";

export interface Availability { available: boolean; reason: string | null }
export interface CapabilityProbes {
  command: (name: string) => boolean;
  desktop: () => Promise<unknown>;
  wayland: () => Promise<string[]>;
}

export const capabilities = new Set<string>();
export const capabilityHealth: Record<string, Availability> = {};

export async function probeCapabilities(probes: CapabilityProbes): Promise<Record<string, Availability>> {
  const health: Record<string, Availability> = {};
  let desktopError: string | null = null;
  let waylandError: string | null = null;
  let globals: string[] = [];
  await Promise.all([
    probes.desktop().catch((error) => { desktopError = (error as Error).message; }),
    probes.wayland().then((value) => { globals = value; }).catch((error) => { waylandError = (error as Error).message; }),
  ]);
  const set = (name: string, reason: string | null) => { health[name] = { available: reason === null, reason }; };
  const tool = (name: string) => probes.command(name) ? null : "Missing command: " + name;
  const protocol = (name: string) => waylandError ?? (globals.includes(name) ? null : "Missing Wayland protocol: " + name);
  for (const name of ["windows.read", "windows.place", "spaces.read", "apps.open", "displays.virtual"]) set(name, desktopError);
  set("capture.still", tool("grim") ?? desktopError ?? protocol("zwlr_screencopy_manager_v1"));
  set("capture.live", tool("wayvnc") ?? health["capture.still"].reason ?? protocol("zwp_virtual_keyboard_manager_v1") ?? protocol("zwlr_virtual_pointer_manager_v1"));
  set("input.keys", tool("wtype") ?? protocol("wl_seat") ?? protocol("zwp_virtual_keyboard_manager_v1"));
  set("input.pointer", desktopError ?? protocol("zwlr_virtual_pointer_manager_v1"));
  set("sessions.tmux", tool("tmux"));
  set("ocr", tool("tesseract") ?? health["capture.still"].reason);
  set("capture.record", tool("ffmpeg") ?? health["capture.still"].reason);
  return health;
}

/** Startup/explicit re-probe only; never on a periodic timer. */
export async function refreshCapabilities() {
  const health = await probeCapabilities({ command: hasCommand, desktop: desktop.snapshot, wayland: waylandGlobals });
  capabilities.clear();
  for (const name of Object.keys(capabilityHealth)) delete capabilityHealth[name];
  for (const [name, result] of Object.entries(health)) {
    capabilityHealth[name] = result;
    if (result.available) capabilities.add(name);
  }
  updateEventHealth(hypr.getEventStreamHealth());
  return capabilities;
}

export function updateEventHealth(health: EventStreamHealth) {
  const available = health.state === "connected";
  capabilityHealth["events.desktop"] = { available, reason: available ? null : health.reason ?? health.state };
  if (available) capabilities.add("events.desktop");
  else capabilities.delete("events.desktop");
}
