import { expect, test } from "bun:test";
import type { ServerWebSocket } from "bun";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

type Json = Record<string, any>;
type Socket = ServerWebSocket<{ id: number; targetId?: string }>;
type Target = {
  id: string;
  url: string;
  width: number;
  height: number;
  owner?: Socket;
};
const NATIVE = { width: 1440, height: 857 };
// The fake exercises capture transport and file output, not Chrome rendering.
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=", "base64");

async function until(check: () => boolean, label: string, timeout = 2_000): Promise<void> {
  const end = performance.now() + timeout;
  while (!check()) {
    if (performance.now() >= end) throw new Error("Timed out waiting for " + label);
    await Bun.sleep(10);
  }
}

/** Run the actual MCP server in a disposable home against a local CDP model. */
async function fixture(idleTimeoutMs = 0) {
  const directory = await mkdtemp(join(tmpdir(), "lattices-viewport-lifecycle-"));
  const home = join(directory, "home");
  const profileRoot = join(directory, "profiles");
  const sessionRoot = join(directory, "sessions");
  await Promise.all([home, profileRoot, sessionRoot].map(path => mkdir(path, { recursive: true })));
  const targets = new Map<string, Target>();
  const sockets = new Set<Socket>();
  const commands: Array<{ method: string; socketId: number; targetId?: string; width?: number; height?: number }> = [];
  const observations: Array<{ kind: string; width: number; height: number }> = [];
  let nextSocketId = 0;
  let alive = true;
  let browserCloses = 0;
  let ownerDisconnects = 0;
  const target: Target = { id: "fixture-tab", url: "about:blank", ...NATIVE };
  targets.set(target.id, target);
  const reset = (page: Target) => { page.owner = undefined; Object.assign(page, NATIVE); };
  const describe = (page: Target, port: number) => ({
    id: page.id, type: "page", title: "Viewport fixture", url: page.url,
    webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${page.id}`,
  });
  const server = Bun.serve<{ id: number; targetId?: string }>({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
      const path = new URL(request.url).pathname;
      if (path.startsWith("/devtools/")) {
        const targetId = path.startsWith("/devtools/page/") ? path.slice("/devtools/page/".length) : undefined;
        if (server.upgrade(request, { data: { id: ++nextSocketId, targetId } })) return;
        return new Response("Expected websocket", { status: 400 });
      }
      if (!alive) return new Response("Fake Chrome closed", { status: 503 });
      if (path === "/json/version") return Response.json({ Browser: "Fake Chrome", webSocketDebuggerUrl: `ws://127.0.0.1:${server.port}/devtools/browser/fixture` });
      if (path === "/json/list") return Response.json([...targets.values()].map(page => describe(page, server.port!)));
      if (path.startsWith("/json/close/")) {
        const id = decodeURIComponent(path.slice("/json/close/".length));
        targets.delete(id);
        for (const socket of sockets) if (socket.data.targetId === id) socket.close();
        return new Response("Target is closing");
      }
      return new Response("Unexpected fake endpoint: " + path, { status: 404 });
    },
    websocket: {
      open(socket) { sockets.add(socket); },
      close(socket) {
        sockets.delete(socket);
        // Chrome drops device metrics when their owning connection detaches.
        // Closing an ordinary action/snapshot connection must not reset them.
        for (const page of [target, ...targets.values()]) {
          if (page.owner === socket) { ownerDisconnects++; reset(page); }
        }
      },
      message(socket, raw) {
        const request = JSON.parse(String(raw)) as { id: number; method: string; params?: Json };
        const params = request.params ?? {};
        const page = socket.data.targetId ? targets.get(socket.data.targetId) : undefined;
        commands.push({ method: request.method, socketId: socket.data.id, targetId: socket.data.targetId,
          ...(request.method === "Emulation.setDeviceMetricsOverride" ? { width: params.width, height: params.height } : {}) });
        let result: Json = {};
        if (request.method === "Browser.close") {
          browserCloses++; alive = false;
          for (const other of sockets) if (other !== socket) other.close();
        } else if (!page) {
          socket.send(JSON.stringify({ id: request.id, error: { message: "No such fake target" } }));
          return;
        } else if (request.method === "Emulation.setDeviceMetricsOverride") {
          page.owner = socket; page.width = params.width; page.height = params.height;
        } else if (request.method === "Emulation.clearDeviceMetricsOverride") {
          if (page.owner === socket) reset(page);
        } else if (request.method === "Runtime.evaluate") {
          const expression = String(params.expression);
          let value: unknown;
          if (expression.includes("width: window.innerWidth")) {
            value = { width: page.width, height: page.height, devicePixelRatio: 1, documentWidth: page.width, documentHeight: page.height };
          } else if (expression.includes("const nodes =")) {
            observations.push({ kind: "snapshot", width: page.width, height: page.height });
            value = { title: "Viewport fixture", url: page.url, text: `Viewport: ${page.width} x ${page.height}`, elements: [] };
          } else if (expression.includes("element.click()") || expression.includes("new InputEvent")) {
            observations.push({ kind: expression.includes("element.click()") ? "click" : "fill", width: page.width, height: page.height });
            value = { selector: "#fixture", valueLength: 4 };
          } else if (expression.includes("document.readyState")) {
            value = { title: "Viewport fixture", documentUrl: page.url, readyState: "complete", pageText: "Viewport fixture" };
          } else if (expression.includes("state.buffer.slice()")) {
            value = { installed: true, fromDocumentStart: true, url: page.url, entries: [] };
          } else if (expression.includes("requestAnimationFrame")) {
            value = true;
          } else {
            socket.send(JSON.stringify({ id: request.id, error: { message: "Unmodelled Runtime.evaluate: " + expression.slice(0, 100) } }));
            return;
          }
          result = { result: { value } };
        } else if (request.method === "Page.navigate") {
          page.url = params.url; result = { frameId: "frame", loaderId: "fixture-loader" };
        } else if (request.method === "Page.getFrameTree") {
          result = { frameTree: { frame: { id: "frame", loaderId: "fixture-loader", url: page.url } } };
        } else if (request.method === "Page.captureScreenshot") {
          observations.push({ kind: "screenshot", width: page.width, height: page.height });
          result = { data: PNG.toString("base64") };
        } else if (!["Page.enable", "Page.addScriptToEvaluateOnNewDocument", "Emulation.setTouchEmulationEnabled"].includes(request.method)) {
          socket.send(JSON.stringify({ id: request.id, error: { message: "Unmodelled CDP command: " + request.method } }));
          return;
        }
        socket.send(JSON.stringify({ id: request.id, result }));
      },
    },
  });
  target.url = `http://127.0.0.1:${server.port}/fixture`;
  const child = Bun.spawn([process.execPath, join(import.meta.dir, "../../server.ts"), "--toolsets", "browser"], {
    cwd: directory, stdin: "pipe", stdout: "pipe", stderr: "pipe",
    env: {
      HOME: home, TMPDIR: directory, PATH: "/usr/bin:/bin:/usr/sbin:/sbin", BUN_INSTALL_AUTO: "disable",
      LATTICES_RUNTIME_DIR: join(directory, "runtime"), ACTION_BROWSER_DEBUG_PORT: String(server.port),
      ACTION_BROWSER_PROFILE_ROOT: profileRoot, ACTION_BROWSER_PROFILE: "fixture", ACTION_BROWSER_SESSION_DIR: sessionRoot,
      ACTION_BROWSER_SESSION: "fixture-owner", ACTION_BROWSER_ARTIFACT_DIR: join(directory, "artifacts"),
      ACTION_BROWSER_IDLE_TIMEOUT_MS: String(idleTimeoutMs), ACTION_BROWSER_SHUTDOWN_TIMEOUT_MS: "1000",
      // Fail closed if a regression tries to launch instead of using the fake.
      ACTION_BROWSER_CHROME_APP: "__lattices_viewport_test_no_such_app__",
    },
  });
  const stderr = new Response(child.stderr).text();
  const reader = child.stdout.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let nextId = 0;
  async function request(method: string, params: Json = {}): Promise<Json> {
    const id = ++nextId;
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        (async () => {
          while (!buffer.includes("\n")) {
            const chunk = await reader.read();
            if (chunk.done) throw new Error("MCP exited: " + await stderr);
            buffer += decoder.decode(chunk.value, { stream: true });
          }
          const end = buffer.indexOf("\n");
          const reply = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
          expect(reply.id).toBe(id);
          if (reply.error) throw new Error(JSON.stringify(reply.error));
          return reply.result;
        })(),
        new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("MCP request timed out: " + method)), 3_000); }),
      ]);
    } finally { clearTimeout(timer); }
  }
  async function tool(name: string, args: Json = {}): Promise<Json> {
    const result = await request("tools/call", { name, arguments: args });
    if (result.isError) throw new Error(name + ": " + JSON.stringify(result.structuredContent));
    expect(result.structuredContent.ok).toBe(true);
    return result.structuredContent;
  }
  async function stop() {
    if (child.exitCode === null) child.stdin.end();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([child.exited, new Promise<never>((_, reject) => {
        timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("MCP did not exit after stdin EOF")); }, 2_500);
      })]);
    } finally { clearTimeout(timer); }
  }
  async function dispose() {
    try { await stop(); } finally {
      if (child.exitCode === null) child.kill("SIGKILL");
      server.stop(true); await child.exited; await stderr;
      await rm(directory, { recursive: true, force: true });
    }
  }
  try { await request("initialize"); } catch (error) { await dispose(); throw error; }
  return {
    directory, target, targets, sockets, commands, observations, tool, stop, dispose,
    get browserCloses() { return browserCloses; },
    get ownerDisconnects() { return ownerDisconnects; },
    async shareClaim() {
      await writeFile(join(sessionRoot, "other-owner.json"), JSON.stringify({
        session: "other-owner", pid: process.pid, profile: "fixture", profileDir: join(profileRoot, "fixture"), debugPort: server.port,
      }));
    },
  };
}

test("viewport stays owned across tool connections, gaps, navigation and repeated resize; reset releases it", async () => {
  const f = await fixture();
  try {
    const resized = await f.tool("browser_resize", { width: 800, height: 600 });
    expect(resized.viewport).toMatchObject({ width: 800, height: 600 });
    await until(() => f.sockets.size === 1, "only the viewport owner to remain");
    const owner = f.target.owner;
    expect(owner).toBeDefined();
    await Bun.sleep(30); // No tool connection should be needed to hold the size.
    expect(f.target.width).toBe(800);
    expect((await f.tool("browser_snapshot")).text).toBe("Viewport: 800 x 600");
    await f.tool("browser_click", { selector: "#fixture", settle: "none" });
    await f.tool("browser_fill", { selector: "#fixture", value: "test", settle: "none" });
    await f.tool("browser_open", { url: f.target.url, waitMs: 1000 });
    const outputPath = join(f.directory, "capture.png");
    expect((await f.tool("browser_screenshot", { outputPath, includeImage: false })).viewport).toMatchObject({ width: 800, height: 600 });
    expect(await readFile(outputPath)).toEqual(PNG);
    await until(() => f.sockets.size === 1, "temporary tool connections to close");
    expect(f.target.owner).toBe(owner);
    expect(f.ownerDisconnects).toBe(0);
    expect(f.observations.map(value => value.kind)).toEqual(["snapshot", "click", "fill", "screenshot"]);
    expect(f.observations.every(value => value.width === 800 && value.height === 600)).toBe(true);
    expect(f.commands.filter(value => value.method === "Emulation.setDeviceMetricsOverride")).toHaveLength(1);
    await f.tool("browser_resize", { width: 900, height: 700 });
    expect(f.target.owner).toBe(owner);
    expect((await f.tool("browser_snapshot")).text).toBe("Viewport: 900 x 700");
    const reset = await f.tool("browser_resize", { reset: true });
    expect(reset.emulated).toBe(false);
    expect(reset.viewport).toMatchObject(NATIVE);
    await until(() => f.sockets.size === 0, "reset to release its owning socket");
    expect(f.target.owner).toBeUndefined();
    expect(f.commands.find(value => value.method === "Emulation.clearDeviceMetricsOverride")?.socketId).toBe(owner!.data.id);
  } finally { await f.dispose(); }
}, 10_000);

for (const mode of ["tab-close", "vanished-target"] as const) {
  test(`viewport owner is released on ${mode}`, async () => {
    const f = await fixture();
    try {
      await f.tool("browser_resize", { width: 800, height: 600 });
      await until(() => f.sockets.size === 1, "viewport owner");
      if (mode === "tab-close") expect((await f.tool("browser_close", { tabId: f.target.id })).closed).toBe(f.target.id);
      else {
        // Model target-list invalidation arriving before its socket-close event.
        f.targets.delete(f.target.id);
        expect((await f.tool("browser_tabs")).tabs).toEqual([]);
      }
      await until(() => f.sockets.size === 0, "removed target owner to close");
      expect(f.target.owner).toBeUndefined();
      expect(f.ownerDisconnects).toBe(1);
    } finally { await f.dispose(); }
  }, 7_000);
}

for (const mode of ["profile-switch", "browser-close", "idle", "stdin-eof"] as const) {
  test(`viewport owner is released on ${mode} while a shared claimant keeps Chrome open`, async () => {
    const f = await fixture(mode === "idle" ? 500 : 0);
    try {
      await f.shareClaim();
      await f.tool("browser_resize", { width: 800, height: 600 });
      await until(() => f.sockets.size === 1, "viewport owner");
      if (mode === "profile-switch") {
        expect(await f.tool("browser_use_profile", { profile: "next-profile" })).toMatchObject({ switched: true, closedPrevious: false });
      } else if (mode === "browser-close") {
        expect(await f.tool("browser_close", { scope: "browser" })).toMatchObject({ closed: false, liveOwners: 1 });
      } else if (mode === "stdin-eof") {
        expect(await f.stop()).toBe(0);
      }
      await until(() => f.sockets.size === 0, "release to close the viewport owner");
      expect(f.target.owner).toBeUndefined();
      expect(f.target.width).toBe(NATIVE.width);
      expect(f.browserCloses).toBe(0);
    } finally { await f.dispose(); }
  }, 7_000);
}
