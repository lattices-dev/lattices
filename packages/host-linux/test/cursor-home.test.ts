import { describe, expect, test } from "bun:test";
import type { HyprMonitor } from "../src/hyprland.ts";
import { bringCursorHome, monitorCentre, pickHomeMonitor } from "../src/cursor-home.ts";
import { Router } from "../src/router.ts";
import { registerEndpoints } from "../src/endpoints.ts";

const monitor = (over: Partial<HyprMonitor> = {}): HyprMonitor => ({
  id: 1, name: "HDMI-A-1", description: "Dell", x: 1920, y: 0,
  width: 3440, height: 1440, scale: 1, transform: 0, reserved: [0, 24, 0, 0],
  activeWorkspace: { id: 1, name: "1" }, focused: true, ...over,
});
describe("home monitor", () => {
  test("focused virtual output never wins over the Dell", () => {
    const dell = monitor({ focused: false });
    expect(pickHomeMonitor([monitor({ name: "LATS-1", x: 0, description: "" }), dell])).toBe(dell);
    expect(monitorCentre(dell)).toEqual({ x: 3640, y: 720 });
  });
  test("prefers focused real monitor, otherwise first real monitor", () => {
    const first = monitor({ focused: false });
    const focused = monitor({ name: "DP-1" });
    expect(pickHomeMonitor([first, focused])).toBe(focused);
    expect(pickHomeMonitor([first, monitor({ focused: false })])).toBe(first);
  });
  test("skips headless, disabled and mirrored outputs; refuses virtual-only layouts", () => {
    const dell = monitor();
    expect(pickHomeMonitor([
      monitor({ name: "HEADLESS-1" }), { ...monitor(), disabled: true },
      { ...monitor(), mirrorOf: "DP-1" }, { ...monitor({ description: "" }), physicalWidth: 0, physicalHeight: 0 }, dell,
    ])).toBe(dell);
    expect(() => pickHomeMonitor([monitor({ name: "LATS-1" })])).toThrow("No real monitor");
    expect(() => pickHomeMonitor([])).toThrow("No real monitor");
  });
  test("uses logical coordinates on scaled, rotated and negative-position monitors", () => {
    expect(monitorCentre(monitor({ x: -1920, y: -100, width: 3840, height: 2160, scale: 2 }))).toEqual({ x: -960, y: 440 });
    expect(monitorCentre(monitor({ x: 0, width: 1920, height: 1080, transform: 1 }))).toEqual({ x: 540, y: 960 });
  });
});


describe("cursor recovery", () => {
  test("warps only through the compositor and reports logical coordinates", async () => {
    const calls: string[][] = [];
    const result = await bringCursorHome({ run: async (command, args) => {
      calls.push([command, ...args]);
      return args[0] === "monitors" ? JSON.stringify([monitor()]) : "ok";
    } });
    expect(result).toEqual({ ok: true, monitor: "HDMI-A-1", x: 3640, y: 720 });
    expect(calls).toEqual([["hyprctl", "monitors", "-j"], ["hyprctl", "dispatch", "movecursor", "3640", "720"]]);
  });
  test("supports the Lua dispatcher and surfaces compositor failure", async () => {
    const calls: string[][] = [];
    const run = async (command: string, args: string[]) => {
      calls.push([command, ...args]);
      if (args[0] === "monitors") return JSON.stringify([monitor()]);
      return args[1] === "movecursor" ? "unknown dispatcher" : "ok";
    };
    await bringCursorHome({ run });
    expect(calls.at(-1)).toEqual(["hyprctl", "dispatch", "hl.dsp.cursor.move({ x = 3640, y = 720 })"]);
    await expect(bringCursorHome({ run: async (command, args) => args[0] === "monitors" ? JSON.stringify([monitor()]) : "failed" })).rejects.toThrow("hyprctl: failed");
  });
  test("home remains a discoverable mutation", () => {
    const router = new Router(() => new Set(["spaces.read"]));
    registerEndpoints(router, { bindHost: "127.0.0.1", startedAt: Date.now(), clientCount: () => 0 });
    expect(router.available().filter(entry => entry.method.startsWith("mouse.")).map(entry => [entry.method, entry.access])).toEqual([["mouse.home", "mutate"]]);
  });
});

test("local recovery command rejects unknown verbs and options", async () => {
  const { runMouseCommand } = await import("../src/mouse-cli.ts");
  let calls = 0;
  const deps = { run: async (_command: string, args: string[]) => {
    calls++;
    return args[0] === "monitors" ? JSON.stringify([monitor()]) : "ok";
  } };
  for (const args of [["mouse-share"], ["mouse-keep"], ["mouse-status"], ["mouse-check"], ["mouse-home", "--expired"]]) {
    await expect(runMouseCommand(args, deps)).rejects.toThrow("Usage:");
  }
  expect(calls).toBe(0);
  expect(await runMouseCommand(["mouse-home"], deps)).toMatchObject({ ok: true });
});
