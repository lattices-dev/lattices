import { describe, expect, test } from "bun:test";
import { runInNewContext } from "node:vm";
import { CDPSession } from "./transport.ts";
import { SETTLE_LAYOUT_EXPRESSION, ViewportSessions } from "./viewport-sessions.ts";

const desktop = { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false };
const narrow = { width: 800, height: 600, deviceScaleFactor: 1, mobile: false };

function fixture() {
  let viewport = desktop;
  let owner: Bun.ServerWebSocket<undefined> | undefined;
  const connections = new Set<Bun.ServerWebSocket<undefined>>();
  const methods: string[] = [];
  const server = Bun.serve<undefined>({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
      if (server.upgrade(request, { data: undefined })) return;
      return new Response("Expected WebSocket", { status: 400 });
    },
    websocket: {
      open(ws) { connections.add(ws); },
      message(ws, data) {
        const request = JSON.parse(String(data));
        methods.push(request.method);
        if (request.method === "Emulation.setDeviceMetricsOverride") {
          owner = ws; viewport = request.params;
        }
        if (request.method === "Emulation.clearDeviceMetricsOverride" && owner === ws) {
          owner = undefined; viewport = desktop;
        }
        ws.send(JSON.stringify({ id: request.id, result: { ...viewport } }));
      },
      close(ws) {
        connections.delete(ws);
        if (owner === ws) { owner = undefined; viewport = desktop; }
      },
    },
  });
  return {
    url: server.url.href.replace("http:", "ws:"), methods, connections,
    viewport: () => viewport,
    disconnectOwner: () => owner?.close(),
    stop: () => server.stop(true),
  };
}

async function until(condition: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100 && !condition(); attempt++) await Bun.sleep(2);
  expect(condition()).toBe(true);
}

describe("persistent browser viewport connections", () => {
  test("temporary action connections cannot undo emulation; update and reset use the same owner", async () => {
    const chrome = fixture();
    const viewports = new ViewportSessions();
    try {
      viewports.set("tab", narrow);
      await viewports.apply("tab", chrome.url);
      for (const operation of ["snapshot", "click", "fill", "screenshot"]) {
        const action = await CDPSession.connect(chrome.url);
        expect(await action.call(operation)).toEqual(narrow);
        action.close();
        await until(() => chrome.connections.size === 1);
        expect(chrome.viewport()).toEqual(narrow);
        await viewports.apply("tab", chrome.url);
      }
      expect(chrome.methods.filter(method => method === "Emulation.setDeviceMetricsOverride")).toHaveLength(1);
      const updated = { ...narrow, width: 390, mobile: true };
      viewports.set("tab", updated);
      await viewports.apply("tab", chrome.url);
      expect(chrome.connections.size).toBe(1);
      expect(chrome.viewport()).toEqual(updated);
      expect(await viewports.reset("tab")).toBe(true);
      await until(() => chrome.connections.size === 0);
      expect(chrome.viewport()).toEqual(desktop);
      expect(viewports.has("tab")).toBe(false);
      expect(chrome.methods).toContain("Emulation.clearDeviceMetricsOverride");
    } finally { viewports.clear(); chrome.stop(); }
  });

  test("a disconnected owner is replaced without forgetting the requested viewport", async () => {
    const chrome = fixture();
    const sessions: CDPSession[] = [];
    const viewports = new ViewportSessions(async url => {
      const session = await CDPSession.connect(url); sessions.push(session); return session;
    });
    try {
      viewports.set("tab", narrow);
      await viewports.apply("tab", chrome.url);
      chrome.disconnectOwner();
      await until(() => !sessions[0].isOpen);
      expect(chrome.viewport()).toEqual(desktop);
      await viewports.apply("tab", chrome.url);
      expect(sessions).toHaveLength(2);
      expect(chrome.viewport()).toEqual(narrow);
      viewports.delete("tab");
      await until(() => chrome.connections.size === 0);
      expect(chrome.viewport()).toEqual(desktop);
    } finally { viewports.clear(); chrome.stop(); }
  });

  test("release during connection creation closes the late connection instead of resurrecting a viewport", async () => {
    const chrome = fixture();
    let finish!: (session: CDPSession) => void;
    const connecting = new Promise<CDPSession>(resolve => { finish = resolve; });
    const viewports = new ViewportSessions(() => connecting);
    try {
      viewports.set("tab", narrow);
      const applying = viewports.apply("tab", chrome.url);
      const outcome = applying.catch(error => error as Error);
      viewports.clear();
      finish(await CDPSession.connect(chrome.url));
      expect(await outcome).toBeInstanceOf(Error);
      expect((await outcome as Error).message).toContain("viewport was released");
      await until(() => chrome.connections.size === 0);
      expect(viewports.size).toBe(0);
      expect(chrome.methods).toEqual([]);
      expect(chrome.viewport()).toEqual(desktop);
    } finally { viewports.clear(); chrome.stop(); }
  });
});

function layoutFixture(visibilityState: "visible" | "hidden") {
  const frames = new Map<number, () => void>();
  const tasks: Array<() => void> = [];
  const listeners = new Set<() => void>();
  let nextFrame = 0;
  let closedPorts = 0;
  const document = {
    visibilityState,
    addEventListener(_type: string, listener: () => void) { listeners.add(listener); },
    removeEventListener(_type: string, listener: () => void) { listeners.delete(listener); },
  };
  const promise = runInNewContext(SETTLE_LAYOUT_EXPRESSION, {
    document,
    requestAnimationFrame(callback: () => void) { frames.set(++nextFrame, callback); return nextFrame; },
    cancelAnimationFrame(id: number) { frames.delete(id); },
    MessageChannel: class {
      port1 = { onmessage: undefined as undefined | (() => void), close() { closedPorts++; } };
      port2 = { postMessage: () => tasks.push(() => this.port1.onmessage?.()), close() { closedPorts++; } };
    },
  }) as Promise<boolean>;
  return {
    promise, frames, tasks, listeners,
    get closedPorts() { return closedPorts; },
    frame() { const callbacks = [...frames.values()]; frames.clear(); for (const callback of callbacks) callback(); },
    hide() { document.visibilityState = "hidden"; for (const listener of listeners) listener(); },
  };
}

describe("viewport layout boundary", () => {
  test("a hidden document settles through a browser task without waiting for paused animation frames", async () => {
    const f = layoutFixture("hidden");
    expect(f.frames.size).toBe(0);
    expect(f.tasks).toHaveLength(1);
    f.tasks.shift()!();
    expect(await f.promise).toBe(true);
    expect(f.listeners.size).toBe(0);
    expect(f.closedPorts).toBe(2);
  });

  test("a visible document waits across two rendering frames and cleans up", async () => {
    const f = layoutFixture("visible");
    expect(f.tasks).toHaveLength(0);
    expect(f.frames.size).toBe(1);
    f.frame();
    expect(f.frames.size).toBe(1);
    f.frame();
    expect(await f.promise).toBe(true);
    expect(f.listeners.size).toBe(0);
    expect(f.closedPorts).toBe(2);
  });

  test("a tab hidden between frames cancels its paused frame and settles without activation", async () => {
    const f = layoutFixture("visible");
    f.frame();
    f.hide();
    expect(f.tasks).toHaveLength(1);
    f.tasks.shift()!();
    expect(await f.promise).toBe(true);
    expect(f.frames.size).toBe(0);
    expect(f.listeners.size).toBe(0);
    expect(f.closedPorts).toBe(2);
  });
});
