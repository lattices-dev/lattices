import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { BridgeSecurity, CAPABILITIES, deriveKeys, openVisitFrame, publicKeyFromBase64, rawPublicKey, sealVisitFrame, visitAAD } from "../src/bridge/security.ts";
import { startBridge } from "../src/bridge/server.ts";
import { VisitTestClient, openVisitSocket, visitHeaders } from "../src/bridge/visit-test.ts";
import { VISIT_SILENCE_MS } from "../src/bridge/visit-channel.ts";
import { VisitArea, VisitSession, clampToScreens, parseVisitMessage, type VisitDependencies, type VisitorOverlay, type VisitorState } from "../src/bridge/visit.ts";
import { wtypeKeysymArgs } from "../src/input.ts";
import type { Monitor } from "../src/cursor-home.ts";

const monitor = (name: string, extra: Partial<Monitor> = {}): Monitor => ({ id: 1, name, description: "Dell", x: 1920, y: 0, width: 3440, height: 1440, scale: 1, transform: 0,
  reserved: [0, 24, 0, 0], activeWorkspace: { id: 1, name: "1" }, focused: true, ...extra });
const monitors = [monitor("LATS-1", { id: 0, description: "", x: 0, width: 1920, height: 1080, physicalWidth: 0, physicalHeight: 0 }), monitor("HDMI-A-1")];

function fixture() {
  const events: unknown[][] = [];
  let state: VisitorState | null = null;
  const overlay: VisitorOverlay = {
    async show(value) { state = value; events.push(["show", value]); },
    update(value) { state = value; events.push(["update", value]); },
    hide() { if (state) state = { ...state, visible: false }; events.push(["hide"]); },
    async stop() { events.push(["stop"]); },
  };
  const deps: VisitDependencies = {
    monitors: async () => monitors, cursor: async () => ({ x: 3000, y: 800 }),
    pointer: async () => {
      events.push(["open"]);
      return { async move(x, y, extent) { events.push(["move", x, y, extent]); },
        async button(button, down) { events.push(["button", button, down]); },
        async scroll(dx, dy) { events.push(["scroll", dx, dy]); }, async close() { events.push(["close"]); } };
    },
    restore: async (point) => { events.push(["restore", point]); },
    key: async (key, mods) => { events.push(["key", ...wtypeKeysymArgs(key, mods)]); },
    text: async (text) => { events.push(["text", text]); }, log: (message) => { events.push(["log", message]); },
  };
  return { overlay, deps, events, state: () => state };
}
const enter = { t: "enter", name: "mini", edge: "left", at: 0.5 } as const;

describe("visit frame crypto", () => {
  const key = randomBytes(32), device = "mini-device", nonce = "upgrade-nonce";
  const plain = Buffer.from('{"t":"move","dx":3,"dy":-2}');
  test("binary combined box round trip and exact AAD", () => {
    expect(visitAAD("up", device, nonce, 0).toString()).toBe("visit\nup\nmini-device\nupgrade-nonce\n0");
    for (const direction of ["up", "down"] as const) {
      const frame = sealVisitFrame(key, plain, direction, device, nonce, 0);
      expect(frame.length).toBe(plain.length + 28);
      expect(openVisitFrame(key, frame, direction, device, nonce, 0)).toEqual(plain);
    }
  });
  test("wrong direction, sequence, device, or upgrade nonce cannot open", () => {
    const frame = sealVisitFrame(key, plain, "up", device, nonce, 0);
    expect(() => openVisitFrame(key, frame, "down", device, nonce, 0)).toThrow();
    expect(() => openVisitFrame(key, frame, "up", device, nonce, 1)).toThrow();
    expect(() => openVisitFrame(key, frame, "up", "other", nonce, 0)).toThrow();
    expect(() => openVisitFrame(key, frame, "up", device, "other", 0)).toThrow();
  });
  test("tampered nonce, ciphertext, tag, and truncated frame fail", () => {
    const frame = sealVisitFrame(key, plain, "up", device, nonce, 0);
    for (const at of [0, 12, frame.length - 1]) {
      const bad = Buffer.from(frame); bad[at] ^= 1;
      expect(() => openVisitFrame(key, bad, "up", device, nonce, 0)).toThrow();
    }
    expect(() => openVisitFrame(key, frame.subarray(0, 27), "up", device, nonce, 0)).toThrow();
  });
});

describe("visit area", () => {
  test("shares the home-monitor filter, excludes virtual outputs and reserved bars", () => {
    const area = new VisitArea([...monitors, monitor("WL-2"), monitor("HEADLESS-1"), monitor("VIRTUAL-3"), monitor("mirror", { mirrorOf: "HDMI-A-1" }), monitor("disabled", { disabled: true })]);
    expect(area.screens.map((s) => s.name)).toEqual(["HDMI-A-1"]);
    expect(area.extent).toEqual({ x: 1920, y: 0, w: 3440, h: 1440 });
    expect(() => new VisitArea([monitors[0]])).toThrow("No real monitor");
  });
  test("enters and exits each edge with a normalized position", () => {
    const area = new VisitArea(monitors);
    expect(area.enter("left", 0.5)).toEqual({ x: 1920, y: 719.5 });
    expect(area.enter("right", 1)).toEqual({ x: 5359, y: 1439 });
    expect(area.enter("top", 0)).toEqual({ x: 1920, y: 0 });
    expect(area.enter("bottom", 0.5)).toEqual({ x: 3639.5, y: 1439 });
    expect(area.exitAt("left", { x: 1919, y: 719.5 })).toBe(0.5);
    expect(area.exitAt("right", { x: 5360, y: 2000 })).toBe(1);
    expect(area.exitAt("top", { x: 3639.5, y: -1 })).toBe(0.5);
    expect(area.exitAt("bottom", { x: 1920, y: 1440 })).toBe(0);
    expect(area.exitAt("left", { x: 5360, y: 100 })).toBeNull();
  });
  test("scaled rotated screens, negative origins and gaps use real coordinates", () => {
    const area = new VisitArea([monitor("DP-1", { x: -720, y: -100, width: 2400, height: 1440, transform: 1, scale: 2 }), monitor("HDMI-A-1", { x: 100, y: 600, width: 800, height: 600 })]);
    expect(area.screens[0]).toMatchObject({ x: -720, y: -100, w: 720, h: 1200 });
    expect(clampToScreens({ x: 50, y: 650 }, area.screens)).toEqual({ x: 100, y: 650 });
    expect(area.enter("left", 1)).toEqual({ x: -720, y: 1099 });
  });
});

describe("visit input and cleanup", () => {
  test("ordinary moves are scale 1 and never move the real pointer", async () => {
    const f = fixture(), session = new VisitSession(f.overlay, f.deps);
    expect(await session.enter(enter)).toEqual({ t: "ready", x: 1920, y: 719.5 });
    await session.perform({ t: "move", dx: 55, dy: -20 });
    expect(f.state()).toMatchObject({ x: 1975, y: 699.5, name: "mini" });
    expect(f.events.filter((e) => e[0] === "move")).toHaveLength(0);
    await session.perform({ t: "move", dx: 10000, dy: 10000 });
    expect(f.state()).toMatchObject({ x: 5359, y: 1439 });
    await session.end();
  });
  test("button, drag and scroll share one pointer, keep clicked focus and restore home", async () => {
    const f = fixture(), session = new VisitSession(f.overlay, f.deps);
    await session.enter(enter);
    await session.perform({ t: "button", button: "left", down: true });
    await session.perform({ t: "move", dx: 30, dy: 40 });
    await session.perform({ t: "button", button: "left", down: false });
    const before = f.events.filter((e) => e[0] === "move").length;
    await session.perform({ t: "move", dx: 10, dy: 0 });
    expect(f.events.filter((e) => e[0] === "move")).toHaveLength(before);
    await session.perform({ t: "scroll", dx: 6, dy: 12 });
    expect(f.events.at(-2)).toEqual(["move", 1960, 759.5, { x: 0, y: 0, w: 5360, h: 1440 }]);
    expect(f.events.at(-1)).toEqual(["scroll", 6, 12]);
    await session.perform({ t: "button", button: "right", down: true });
    await session.end(); await session.end();
    expect(f.events.filter((e) => e[0] === "open")).toHaveLength(1);
    expect(f.events.filter((e) => e[0] === "close")).toHaveLength(1);
    expect(f.events.slice(-4)).toEqual([["hide"], ["button", "right", false], ["move", 3000, 800, { x: 0, y: 0, w: 5360, h: 1440 }], ["close"]]);
  });
  test("exit releases held buttons and hides the overlay", async () => {
    const f = fixture(), session = new VisitSession(f.overlay, f.deps);
    await session.enter(enter);
    await session.perform({ t: "button", button: "middle", down: true });
    expect(await session.perform({ t: "move", dx: -1, dy: 0 })).toEqual({ t: "exit", edge: "left", at: 0.5 });
    expect(f.state()?.visible).toBe(false);
    expect(f.events).toContainEqual(["button", "middle", false]);
    expect(f.events.at(-1)).toEqual(["close"]);
  });
  test("one keysym stroke with super mapped to logo, text unchanged", async () => {
    const f = fixture(), session = new VisitSession(f.overlay, f.deps);
    await session.enter(enter);
    await session.perform({ t: "key", key: "F5", mods: ["super", "shift"] });
    await session.perform({ t: "text", text: "héllo 世界" });
    expect(f.events).toContainEqual(["key", "-M", "logo", "-M", "shift", "-k", "F5", "-m", "shift", "-m", "logo"]);
    expect(f.events.at(-1)).toEqual(["text", "héllo 世界"]);
    await session.perform({ t: "key", key: "Delete", mods: [] });
    await session.perform({ t: "key", key: "A", mods: [] });
    expect(f.events).toContainEqual(["key", "-k", "Delete"]);
    expect(f.events).toContainEqual(["key", "-k", "A"]);
    await session.end();
  });
  test("failed pointer restore still uses recovery and closes the connection", async () => {
    const f = fixture();
    f.deps.pointer = async () => ({ async move() { throw new Error("disconnected"); }, async button() { throw new Error("disconnected"); }, async scroll() {}, async close() { f.events.push(["close"]); } });
    const session = new VisitSession(f.overlay, f.deps);
    await session.enter(enter);
    await session.end();
    expect(f.events).toContainEqual(["restore", { x: 3000, y: 800 }]);
    expect(f.events.at(-1)).toEqual(["close"]);
  });
  test("overlay startup failure tears down the pointer", async () => {
    const f = fixture(); f.overlay.show = async () => { throw new Error("missing quickshell"); };
    const session = new VisitSession(f.overlay, f.deps);
    await expect(session.enter(enter)).rejects.toThrow("missing quickshell");
    expect(f.events.at(-1)).toEqual(["close"]);
  });
});

test("visit schema rejects invalid input before desktop operations", () => {
  for (const value of [null, [], { t: "unknown" }, { ...enter, at: 2 }, { ...enter, edge: "west" }, { ...enter, name: "\nmini" },
    { t: "move", dx: Infinity, dy: 0 }, { t: "button", button: "extra", down: true }, { t: "button", button: "left", down: 1 },
    { t: "key", key: "a", mods: ["command"] }, { t: "key", key: "--", mods: [] }, { t: "key", key: "a", mods: ["ctrl", "ctrl"] },
    { t: "text", text: "a\0b" }]) expect(() => parseVisitMessage(value)).toThrow();
  expect(parseVisitMessage({ t: "key", key: "XF86AudioPlay", mods: ["super"] }).t).toBe("key");
});

async function setup(silenceMs = VISIT_SILENCE_MS) {
  const dir = mkdtempSync("/tmp/visit-test-");
  const privateKey = generateKeyPairSync("x25519").privateKey;
  const security = new BridgeSecurity({ bridgeName: "test", privateKey, devicesPath: join(dir, "devices.json"), approve: async () => true });
  const f = fixture();
  const bridge = startBridge({ hosts: ["127.0.0.1"], port: 0, version: "test", log() {}, trackpadAvailable: () => true, hasTmux: () => false,
    security, visitOverlay: f.overlay, visitDependencies: f.deps, visitSilenceMs: silenceMs });
  const base = `http://127.0.0.1:${bridge.port}`;
  const clientKey = generateKeyPairSync("x25519");
  const client = new VisitTestClient(base, clientKey.privateKey, "mini");
  await client.pair(() => {});
  const keys = deriveKeys(clientKey.privateKey, publicKeyFromBase64(security.publicKeyBase64)!);
  return { ...f, bridge, security, base, client, keys, async stop() { await bridge.stop(); rmSync(dir, { recursive: true, force: true }); } };
}
async function until(check: () => boolean) {
  const deadline = Date.now() + 1000;
  while (!check()) { if (Date.now() >= deadline) throw new Error("condition timed out"); await Bun.sleep(2); }
}

describe("visit WebSocket", () => {
  test("upgrade checks signed auth and input.trackpad, rejects replayed upgrades", async () => {
    const f = await setup();
    try {
      expect((await fetch(`${f.base}/visit`)).status).toBe(401);
      const headers = visitHeaders(f.keys.signing, f.client.deviceID);
      expect((await fetch(`${f.base}/visit`, { headers })).status).toBe(400);
      expect((await fetch(`${f.base}/visit`, { headers })).status).toBe(401);
      const deniedKey = generateKeyPairSync("x25519");
      await f.security.handlePairing({ deviceID: "read-only", deviceName: "read-only", devicePublicKey: rawPublicKey(deniedKey.publicKey).toString("base64"), platform: "test", requestedCapabilities: [CAPABILITIES.deckRead] });
      const keys = deriveKeys(deniedKey.privateKey, publicKeyFromBase64(f.security.publicKeyBase64)!);
      expect((await fetch(`${f.base}/visit`, { headers: visitHeaders(keys.signing, "read-only") })).status).toBe(403);
    } finally { await f.stop(); }
  });
  test("ready, pong and exit are encrypted with independent down sequences", async () => {
    const f = await setup();
    try {
      const visit = await f.client.connect();
      visit.send(enter); expect(await visit.waitFor("ready")).toEqual({ t: "ready", x: 1920, y: 719.5 });
      visit.send({ t: "ping" }); expect(await visit.waitFor("pong")).toEqual({ t: "pong" });
      visit.send({ t: "button", button: "left", down: true });
      visit.send({ t: "move", dx: -1, dy: 0 });
      expect(await visit.waitFor("exit")).toEqual({ t: "exit", edge: "left", at: 0.5 });
      await until(() => f.events.some((e) => e[0] === "close"));
      expect(f.events).toContainEqual(["button", "left", false]);
    } finally { await f.stop(); }
  });
  test("text frames, bad JSON, wrong sequence/direction and tampering close 1008", async () => {
    const f = await setup();
    try {
      for (const kind of ["text", "json", "seq", "direction", "tamper", "replay"]) {
        const nonce = randomUUID();
        const ws = openVisitSocket(`${f.base.replace("http", "ws")}/visit`, visitHeaders(f.keys.signing, f.client.deviceID, nonce));
        const closed = new Promise<CloseEvent>((resolve) => ws.addEventListener("close", resolve, { once: true }));
        await new Promise<void>((resolve) => ws.addEventListener("open", () => resolve(), { once: true }));
        let frame = sealVisitFrame(f.keys.encryption, Buffer.from(kind === "json" ? "{bad" : '{"t":"ping"}'), kind === "direction" ? "down" : "up", f.client.deviceID, nonce, kind === "seq" ? 1 : 0);
        if (kind === "tamper") frame[12] ^= 1;
        if (kind === "text") ws.send("hello"); else ws.send(frame);
        if (kind === "replay") ws.send(frame);
        expect((await closed).code).toBe(1008);
      }
    } finally { await f.stop(); }
  });
  test("disconnect and explicit leave release input and restore home", async () => {
    const f = await setup();
    try {
      for (const disconnect of [true, false]) {
        const visit = await f.client.connect();
        visit.send(enter); await visit.waitFor("ready");
        visit.send({ t: "button", button: "right", down: true });
        await until(() => f.events.some((e) => e[0] === "button" && e[1] === "right" && e[2] === true));
        if (disconnect) visit.close(); else visit.send({ t: "leave" });
        await until(() => f.events.some((e) => e[0] === "close"));
        expect(f.events).toContainEqual(["button", "right", false]);
        expect(f.events).toContainEqual(["move", 3000, 800, { x: 0, y: 0, w: 5360, h: 1440 }]);
        f.events.length = 0;
      }
    } finally { await f.stop(); }
  });
  test("a second visitor cannot steal the seat, and can enter after the owner leaves", async () => {
    const f = await setup();
    try {
      const a = await f.client.connect(), b = await f.client.connect();
      a.send(enter); await a.waitFor("ready");
      b.send(enter); await expect(b.waitFor("ready")).rejects.toThrow("Another visit");
      a.send({ t: "leave" }); await until(() => f.events.some((e) => e[0] === "close"));
      b.send(enter); expect((await b.waitFor("ready")).t).toBe("ready");
      b.close();
    } finally { await f.stop(); }
  });
  test("six-second silence policy resets on authenticated input and cleans up", async () => {
    expect(VISIT_SILENCE_MS).toBe(6000);
    const f = await setup(100);
    try {
      const visit = await f.client.connect(); visit.send(enter); await visit.waitFor("ready");
      visit.send({ t: "button", button: "middle", down: true });
      await Bun.sleep(60); visit.send({ t: "ping" }); await visit.waitFor("pong");
      await Bun.sleep(60); expect(f.events.some((e) => e[0] === "close")).toBe(false);
      await until(() => f.events.some((e) => e[0] === "close"));
      expect(f.events).toContainEqual(["button", "middle", false]);
      expect(f.state()?.visible).toBe(false);
    } finally { await f.stop(); }
  });
  test("close during a slow enter serializes cleanup after pointer creation", async () => {
    const f = await setup();
    let resume!: () => void;
    const gate = new Promise<void>((resolve) => { resume = resolve; });
    const pointer = f.deps.pointer;
    f.deps.pointer = async () => { f.events.push(["opening"]); await gate; return pointer(); };
    try {
      const visit = await f.client.connect(); visit.send(enter);
      await until(() => f.events.some((e) => e[0] === "opening"));
      visit.close(); resume();
      await until(() => f.events.some((e) => e[0] === "close"));
      expect(f.state()?.visible).toBe(false);
    } finally { resume(); await f.stop(); }
  });
  test("bridge shutdown completes held-button cleanup before returning", async () => {
    const f = await setup();
    try {
      const visit = await f.client.connect(); visit.send(enter); await visit.waitFor("ready");
      visit.send({ t: "button", button: "left", down: true });
      await until(() => f.events.some((e) => e[0] === "button"));
      await f.bridge.stop();
      expect(f.events).toContainEqual(["button", "left", false]);
      expect(f.events.at(-1)).toEqual(["stop"]);
    } finally { await f.stop(); }
  });
  test("an overlay crash ends the visit and releases its held buttons", async () => {
    const f = await setup();
    try {
      const visit = await f.client.connect(); visit.send(enter); await visit.waitFor("ready");
      visit.send({ t: "button", button: "left", down: true });
      await until(() => f.events.some((e) => e[0] === "button"));
      f.overlay.onFailure?.(new Error("quickshell crashed"));
      await until(() => f.events.some((e) => e[0] === "close"));
      expect(f.events).toContainEqual(["button", "left", false]);
      expect(f.state()?.visible).toBe(false);
    } finally { await f.stop(); }
  });
});
