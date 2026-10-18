import { describe, expect, test } from "bun:test";
import { admit, isLoopback } from "../src/auth.ts";
import { grimArgs, imageSize } from "../src/capture.ts";
import { isVirtual, toDisplays, toWindow, widFor, type Display, type Window } from "../src/desktop.ts";
import { clear as clearOrigins, get as getOrigin, record as recordOrigin, returnOps } from "../src/moves.ts";
import { monitorRule, nextName, validName } from "../src/displays.ts";

import { keyLabel, toEvent, typeLabel } from "../src/acted.ts";

import { spell, type HyprClient, type HyprMonitor, type HyprWorkspace } from "../src/hyprland.ts";
import { keysym, parseShortcut, wtypeKeyArgs } from "../src/input.ts";
import { parsePlacement, rectFor } from "../src/placement.ts";
import { Router, resolveAlias } from "../src/router.ts";
import { sessionName } from "../src/tmux.ts";
import { find, matchScore, parseTsv } from "../src/ocr.ts";
import { handleSubscription } from "../src/server.ts";
import { encodeMessage } from "../src/wayland.ts";

describe("router", () => {
  const caps = new Set(["windows.read"]);
  const router = new Router(() => caps);
  router.register({ method: "windows.list", description: "", access: "read", capability: "windows.read", returns: "", handler: () => [1] });
  router.register({ method: "windows.place", description: "", access: "mutate", capability: "windows.place", returns: "", handler: (p) => p.placement ?? null });
  router.register({ method: "tmux.list", description: "", access: "read", returns: "", handler: (p) => p.includeOrphans ?? false });

  test("dispatches new names and old aliases", async () => {
    expect(await router.dispatch("windows.list", {})).toEqual([1]);
    expect(await router.dispatch("tmux.inventory", null)).toBe(true);
    expect(await router.dispatch("tmux.sessions", null)).toBe(false);
  });

  test("window.tile maps position to placement", () => {
    expect(resolveAlias("window.tile", { session: "a", position: "left" })).toEqual({
      method: "windows.place",
      params: { session: "a", position: "left", placement: "left" },
    });
  });

  test("unknown methods use the daemon's error text, which clients key their fallback on", async () => {
    const res = await router.handle({ id: "1", method: "windows.nope" });
    expect(res).toEqual({ id: "1", result: null, error: "Unknown method: windows.nope" });
  });

  test("endpoints without their capability are refused and left out of the schema", async () => {
    await expect(router.dispatch("windows.place", { placement: "left" })).rejects.toThrow("capability_unavailable");
    const schema = router.schema() as { methods: { method: string }[]; aliases: Record<string, string> };
    expect(schema.methods.map((m) => m.method)).toEqual(["windows.list", "tmux.list"]);
    expect(schema.aliases["tmux.sessions"]).toBe("tmux.list");
    expect(schema.aliases["window.place"]).toBeUndefined();
  });
});

describe("placement", () => {
  test("named tiles match the Mac table", () => {
    expect(parsePlacement("left")).toEqual({ x: 0, y: 0, w: 0.5, h: 1 });
    expect(parsePlacement("bottom-right")).toEqual({ x: 0.5, y: 0.5, w: 0.5, h: 0.5 });
    expect(parsePlacement("center")).toEqual({ x: 0.1, y: 0.1, w: 0.8, h: 0.8 });
    expect(parsePlacement("right-quarter")).toEqual({ x: 0.75, y: 0, w: 0.25, h: 1 });
    expect(parsePlacement("MAX")).toEqual({ x: 0, y: 0, w: 1, h: 1 });
  });

  test("grid:CxR:C,R is 0-indexed, compact CxR:C,R is 1-indexed", () => {
    expect(parsePlacement("grid:3x2:2,1")).toEqual(parsePlacement("3x2:3,2"));
    expect(parsePlacement({ kind: "grid", columns: 4, rows: 4, column: 0, row: 0 })).toEqual({ x: 0, y: 0, w: 0.25, h: 0.25 });
  });

  test("rejects what it cannot place", () => {
    expect(() => parsePlacement("diagonal")).toThrow("Unknown placement");
    expect(() => parsePlacement("grid:2x2:2,0")).toThrow("Invalid grid");
    expect(() => parsePlacement({ kind: "fractions", x: 0.8, y: 0, w: 0.5, h: 1 })).toThrow("Invalid fractions");
  });

  test("rectFor fills the visible frame without gaps between neighbours", () => {
    const visible = { x: 0, y: 24, w: 3440, h: 1416 };
    const left = rectFor(parsePlacement("left-third"), visible);
    const middle = rectFor(parsePlacement("center-third"), visible);
    expect(left).toEqual({ x: 0, y: 24, w: 1147, h: 1416 });
    expect(middle.x).toBe(left.x + left.w);
  });
});

const monitor = (over: Partial<HyprMonitor> = {}): HyprMonitor => ({
  id: 1,
  name: "HDMI-A-1",
  description: "Dell",
  x: 0,
  y: 0,
  width: 3440,
  height: 1440,
  scale: 1,
  transform: 0,
  reserved: [0, 24, 0, 0],
  activeWorkspace: { id: 1, name: "1" },
  focused: true,
  ...over,
});

const client = (over: Partial<HyprClient> = {}): HyprClient => ({
  address: "0x562f8237b450",
  mapped: true,
  hidden: false,
  at: [10, 36],
  size: [700, 500],
  workspace: { id: 1, name: "1" },
  floating: false,
  monitor: 1,
  class: "foot",
  title: "[lattices:api-b4c5d6] zsh",
  pid: 42,
  xwayland: false,
  pinned: false,
  fullscreen: 0,
  focusHistoryID: 0,
  stableId: "18000032",
  ...over,
});

describe("desktop mapping", () => {
  test("wid comes from the hex stableId, else the address", () => {
    expect(widFor({ address: "0x1", stableId: "18000032" })).toBe(0x18000032);
    expect(widFor({ address: "0x562f8237b450" })).toBe(0x8237b450);
  });

  test("windows take the Mac's shape, with session tags parsed", () => {
    const w = toWindow(client(), [monitor()], "0x562f8237b450");
    expect(w).toMatchObject({ wid: 0x18000032, app: "foot", frame: { x: 10, y: 36, w: 700, h: 500 }, spaceIds: [1], isOnScreen: true, isFocused: true, latticesSession: "api-b4c5d6" });
    expect(toWindow(client({ workspace: { id: 3, name: "3" } }), [monitor()], null).isOnScreen).toBe(false);
  });

  test("displays subtract reserved space and convert physical size to logical", () => {
    const workspaces: HyprWorkspace[] = [
      { id: 2, name: "2", monitor: "HDMI-A-1", monitorID: 1, windows: 1 },
      { id: 1, name: "1", monitor: "HDMI-A-1", monitorID: 1, windows: 4 },
      { id: -98, name: "special:magic", monitor: "HDMI-A-1", monitorID: 1, windows: 0 },
    ];
    const [d] = toDisplays([monitor({ scale: 2, width: 3440, height: 1440 })], workspaces);
    expect(d.frame).toEqual({ x: 0, y: 0, w: 1720, h: 720 });
    expect(d.visibleFrame).toEqual({ x: 0, y: 24, w: 1720, h: 696 });
    expect(d.spaces.map((s) => [s.id, s.index, s.isCurrent])).toEqual([[1, 1, true], [2, 2, false]]);
  });

  test("display indexes run left to right", () => {
    const ds = toDisplays([monitor({ id: 5, name: "right", x: 3440 }), monitor({ id: 1, name: "left", x: 0 })], []);
    expect(ds.map((d) => d.displayId)).toEqual(["left", "right"]);
  });
});

describe("hyprland dialects", () => {
  test("Lua dispatchers (0.55+)", () => {
    expect(spell({ op: "resize", address: "0xab", w: 900.4, h: 600 }, true)).toBe('hl.dsp.window.resize({ x = 900, y = 600, window = "address:0xab" })');
    expect(spell({ op: "toWorkspace", address: "0xab", workspace: 7 }, true)).toBe('hl.dsp.window.move({ workspace = 7, follow = false, window = "address:0xab" })');
    expect(spell({ op: "focus", address: "0xab" }, true)).toBe('hl.dsp.focus({ window = "address:0xab" })');
  });

  test("legacy dispatchers", () => {
    expect(spell({ op: "move", address: "0xab", x: 0, y: 24 }, false)).toBe("movewindowpixel exact 0 24,address:0xab");
    expect(spell({ op: "float", address: "0xab" }, false)).toBe("setfloating address:0xab");
  });
});

describe("input", () => {
  test("Mac modifiers map to Linux ones", () => {
    expect(wtypeKeyArgs("p", ["command", "shift"])).toEqual(["-M", "ctrl", "-M", "shift", "-k", "p", "-m", "shift", "-m", "ctrl"]);
    expect(wtypeKeyArgs("escape", [], 2, 50)).toEqual(["-k", "Escape", "-s", "50", "-k", "Escape"]);
    expect(() => wtypeKeyArgs("a", ["hyper"])).toThrow("Unknown modifier");
  });

  test("key names and shortcuts", () => {
    expect(keysym("Enter")).toBe("Return");
    expect(keysym("f12")).toBe("F12");
    expect(keysym("/")).toBe("slash");
    expect(parseShortcut("command+shift+p")).toEqual({ modifiers: ["command", "shift"], key: "p" });
  });
});

describe("wayland wire format", () => {
  test("bind with a typed new_id: name, padded string, version, id", () => {
    const msg = encodeMessage(2, 0, [{ u: 7 }, { s: "wl_seat" }, { u: 1 }, { u: 3 }]);
    expect(msg.readUInt32LE(0)).toBe(2);
    expect(msg.readUInt32LE(4)).toBe((msg.length << 16) | 0);
    expect(msg.readUInt32LE(12)).toBe(8); // "wl_seat\0"
    expect(msg.subarray(16, 23).toString()).toBe("wl_seat");
    expect(msg.length).toBe(8 + 4 + 4 + 8 + 4 + 4);
  });

  test("fixed-point is value * 256", () => {
    expect(encodeMessage(5, 3, [{ fixed: 15 }]).readInt32LE(8)).toBe(3840);
  });
});

describe("auth", () => {
  const policy = { allowUsers: ["963427367505682"], allowTags: ["tag:lattices"] };

  test("admits this owner's untagged devices and allowed tags only", () => {
    expect(admit({ Node: { User: 963427367505682, Hostinfo: { Hostname: "air", OS: "macOS" } }, UserProfile: { LoginName: "arach@github" } }, policy)).toEqual({ user: "arach@github", node: "air", os: "macOS" });
    expect(admit({ Node: { User: 1, Hostinfo: { Hostname: "stranger" } } }, policy)).toBeNull();
    expect(admit({ Node: { User: 963427367505682, Tags: ["tag:server"] } }, policy)).toBeNull();
    expect(admit({ Node: { User: 5, Tags: ["tag:lattices"], Hostinfo: { Hostname: "ci" } } }, policy)?.node).toBe("ci");
  });

  test("loopback is local", () => {
    expect(isLoopback("127.0.0.1")).toBe(true);
    expect(isLoopback("::ffff:127.0.0.1")).toBe(true);
    expect(isLoopback("100.104.66.99")).toBe(false);
  });
});

describe("tmux and capture", () => {
  test("session names follow the Mac rule", () => {
    expect(sessionName("/Users/you/dev/my app")).toMatch(/^my-app-[0-9a-f]{6}$/);
    expect(sessionName("/a/b")).toBe(sessionName("/a/b"));
  });

  test("grim arguments", () => {
    expect(grimArgs({ region: { x: 1.4, y: 2, w: 300, h: 200 }, format: "jpeg", quality: 70, scale: 0.5 })).toEqual(["-t", "jpeg", "-q", "70", "-s", "0.5", "-g", "1,2 300x200", "-"]);
    expect(grimArgs({ output: "HDMI-A-1" })).toEqual(["-t", "png", "-o", "HDMI-A-1", "-"]);
  });

  test("image size from PNG and JPEG headers", () => {
    const png = Buffer.alloc(32);
    png.writeUInt32BE(0x89504e47, 0);
    png.writeUInt32BE(640, 16);
    png.writeUInt32BE(480, 20);
    expect(imageSize(png)).toEqual({ width: 640, height: 480 });
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x01, 0xe0, 0x02, 0x80, 0, 0, 0, 0, 0]);
    expect(imageSize(jpeg)).toEqual({ width: 640, height: 480 });
  });
});

describe("ocr", () => {
  const tsv = [
    "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext",
    "5\t1\t1\t1\t1\t1\t20\t10\t100\t30\t91\tHetlo",
    "5\t1\t1\t1\t1\t2\t130\t12\t120\t28\t89\tRenote",
    "5\t1\t1\t1\t1\t3\t260\t10\t130\t30\t95\tEngine",
    "5\t1\t1\t1\t2\t1\t20\t60\t140\t30\t96\tsecond",
    "4\t1\t1\t1\t2\t0\t20\t60\t140\t30\t-1\t",
  ].join("\n");

  test("words group into lines mapped back to screen coordinates", () => {
    // A 2x capture of a region at (1000, 400).
    const lines = parseTsv(tsv, { x: 1000, y: 400, w: 500, h: 300 }, 2);
    expect(lines.map((l) => l.text)).toEqual(["Hetlo Renote Engine", "second"]);
    expect(lines[0].frame).toEqual({ x: 20, y: 10, width: 370, height: 30 });
    expect(lines[0].screenFrame).toEqual({ x: 1010, y: 405, w: 185, h: 15 });
    expect(lines[0].confidence).toBeCloseTo(0.9167, 3);
  });

  test("find tolerates OCR misreads and ranks exact lines first", () => {
    expect(matchScore("Hetlo Renote Engine", "Hello Remote Engine")).toBeGreaterThan(0.85);
    expect(matchScore("something else", "Hello Remote Engine")).toBeLessThan(0.5);
    const lines = parseTsv(tsv, { x: 0, y: 0, w: 500, h: 300 }, 1);
    expect(find(lines, "remote engine")[0].text).toBe("Hetlo Renote Engine");
    expect(find(lines, "nothing like it")).toEqual([]);
  });
});

describe("event subscriptions", () => {
  test("all by default, narrowed by subscribe, widened by *", () => {
    const conn = { identity: { user: "u", node: "n" }, events: null as Set<string> | null };
    expect(handleSubscription(conn, "events.subscribe", { events: ["windows.changed"] })).toEqual({ ok: true, events: ["windows.changed"] });
    expect(handleSubscription(conn, "events.subscribe", { events: ["*"] })).toEqual({ ok: true, events: ["*"] });
    expect(conn.events).toBeNull();
  });

  test("unsubscribe removes from all, or stops everything without a list", () => {
    const conn = { identity: { user: "u", node: "n" }, events: null as Set<string> | null };
    expect(handleSubscription(conn, "events.unsubscribe", { events: ["spaces.changed"] })?.events).toEqual(["computer.acted", "host.healthChanged", "layers.changed", "virtual.changed", "windows.changed"]);

    expect(handleSubscription(conn, "events.unsubscribe", {})?.events).toEqual([]);
    expect(handleSubscription(conn, "windows.list", {})).toBeNull();
  });
});

describe("windows.moveBack", () => {
  const win = (over: Partial<Window>): Window => ({
    wid: 1, address: "0xabc", app: "foot", pid: 1, title: "", frame: { x: 0, y: 0, w: 800, h: 600 }, spaceIds: [2], displayIndex: 0,
    isOnScreen: true, isFloating: false, isFullscreen: false, isFocused: false, ...over,
  });

  test("a tiled window goes back to its workspace and is re-tiled if it was floated", () => {
    const origin = { workspace: 2, floating: false, frame: { x: 0, y: 0, w: 800, h: 600 }, movedAt: 0 };
    expect(returnOps(win({ spaceIds: [4], isFloating: true }), origin)).toEqual([
      { op: "toWorkspace", address: "0xabc", workspace: 2 },
      { op: "tile", address: "0xabc" },
    ]);
    expect(returnOps(win({}), origin)).toEqual([]);
  });

  test("a floating window gets its exact frame back", () => {
    const origin = { workspace: 2, floating: true, frame: { x: 100, y: 50, w: 640, h: 480 }, movedAt: 0 };
    expect(returnOps(win({ spaceIds: [4], isFloating: true, frame: { x: 3000, y: 0, w: 1000, h: 700 } }), origin)).toEqual([
      { op: "toWorkspace", address: "0xabc", workspace: 2 },
      { op: "resize", address: "0xabc", w: 640, h: 480 },
      { op: "move", address: "0xabc", x: 100, y: 50 },
    ]);
  });

  test("the first move is the origin until the window is moved back", () => {
    clearOrigins();
    recordOrigin(win({ spaceIds: [2] }));
    recordOrigin(win({ spaceIds: [4] }));
    expect(getOrigin(1)?.workspace).toBe(2);
  });

  test("tile spells for both dialects", () => {
    expect(spell({ op: "tile", address: "0xabc" }, true)).toBe('hl.dsp.window.float({ action = "disable", window = "address:0xabc" })');
    expect(spell({ op: "tile", address: "0xabc" }, false)).toBe("settiled address:0xabc");
  });
});

describe("virtual displays", () => {
  test("names default to the next free LATS-n and must be safe to quote", () => {
    expect(nextName(["HDMI-A-1"])).toBe("LATS-1");
    expect(nextName(["LATS-1", "LATS-3"])).toBe("LATS-2");
    expect(validName("LATS-1")).toBe(true);
    expect(validName('x"; os.exit()')).toBe(false);
    expect(validName("")).toBe(false);
  });

  test("the monitor rule is Lua on 0.55+ and a keyword before", () => {
    const spec = { width: 2880, height: 1800, scale: 2, refresh: 60 };
    expect(monitorRule("LATS-1", spec, true)).toEqual([
      "eval",
      'hl.monitor({ output = "LATS-1", mode = "2880x1800@60", position = "auto", scale = 2 })',
    ]);
    expect(monitorRule("LATS-1", spec, false)).toEqual(["keyword", "monitor", "LATS-1,2880x1800@60,auto,2"]);
  });

  test("headless outputs have no EDID identity", () => {
    expect(isVirtual({ make: "", model: "", serial: "" })).toBe(true);
    expect(isVirtual({ make: "Dell Inc.", model: "AW3425DWM", serial: "JWLC444" })).toBe(false);

  });
});

describe("computer.acted", () => {
  const display = (displayIndex: number, x: number, w: number, h: number) =>
    ({ displayIndex, displayId: `D${displayIndex}`, name: "", virtual: false, frame: { x, y: 0, w, h }, visibleFrame: { x, y: 0, w, h }, scale: 1, currentSpaceId: 1, spaces: [] }) as Display;
  const displays = [display(0, 0, 1440, 900), display(1, 1440, 3440, 1440)];

  test("a pointer action lands on the display under its point, with a ratio for the overlay", () => {
    expect(toEvent({ kind: "click", label: "Click", point: { x: 3160.4, y: 720 }, wid: 7 }, displays, undefined, 1)).toEqual({
      kind: "click", label: "Click", point: { x: 3160, y: 720 }, to: null, wid: 7, element: null,
      displayIndex: 1, ratio: { x: 0.5, y: 0.5 }, toRatio: null, at: 1,
    });
  });

  test("a keyboard action uses the target window's display and has no point", () => {
    const e = toEvent({ kind: "hotkey", label: keyLabel("p", ["ctrl", "shift"], 1) }, displays, 0, 1);
    expect(e.label).toBe("ctrl+shift+p");
    expect(e.displayIndex).toBe(0);
    expect(e.point).toBeNull();
  });

  test("typed text never reaches the label", () => {
    expect(typeLabel(12, true)).toBe("Type 12 chars + Enter");
    expect(typeLabel(1, false)).toBe("Type 1 char");

  });
});
