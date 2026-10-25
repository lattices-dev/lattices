import { expect, test } from "bun:test";
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { mkdtempSync, rmSync, lstatSync, linkSync, symlinkSync, chmodSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { GatewayPairing } from "../src/pairing.ts";
import { gatewayHandlers, startGateway } from "../src/server.ts";
import { authorizeMethod, canonicalProduct, grantsForScope, isTailnetAddress, requestedGrants, scopesHeld, validGrant } from "../src/policy.ts";
import { PAIRING_COOLDOWN_MS, PairingLimits, pairingIdentity } from "../src/pairing-limits.ts";
import { PairingApprovals } from "../../host-linux/src/bridge/approval.ts";
import { canonicalRequest, deriveKeys, publicKeyFromBase64, rawPublicKey, sign, HEADERS } from "../../host-linux/src/bridge/security.ts";
import { privateToken, privateWebSocket, prepareSocket } from "../../host-linux/src/private-ipc.ts";
import { Router } from "../../host-linux/src/router.ts";
import { serve } from "../../host-linux/src/server.ts";
import { daemonCallTo } from "../../desktop-client/daemon-client.ts";
import { localEndpoint } from "../../desktop-client/local-ipc.ts";
import { currentRequestContext } from "../../host-linux/src/request-context.ts";
import { loadOrCreateBridgeKey } from "../../host-linux/src/bridge/security.ts";
import { appendAudit } from "../src/audit.ts";
import { callProduct, canvasSocketPath } from "../src/products.ts";

const WS = WebSocket as unknown as { new(url: string, options?: Bun.WebSocketOptions): WebSocket };
async function open(url: string, headers: Record<string, string> = {}) {
  const ws = new WS(url, { headers });
  await new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = () => reject(new Error("WebSocket rejected")); });
  return ws;
}
function rpc(ws: WebSocket, method: string, params: unknown = {}): Promise<any> {
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.removeEventListener("message", listener); reject(new Error("RPC timeout: " + method)); }, 2000);
    const listener = (event: MessageEvent) => {
      const reply = JSON.parse(String(event.data));
      if (reply.id !== id) return;
      clearTimeout(timer); ws.removeEventListener("message", listener); resolve(reply);
    };
    ws.addEventListener("message", listener); ws.send(JSON.stringify({ id, method, params }));
  });
}
async function waitFor(predicate: () => boolean) { for (let i = 0; i < 100; i++) { if (predicate()) return; await Bun.sleep(5); } throw new Error("Condition timeout"); }

test("gateway grants are exact, scoped to products, and fail closed on aliases and unknown methods", () => {
  const read = grantsForScope("lattices", "read");
  expect(authorizeMethod(read, "lattices", "windows.list")).toBeNull();
  expect(authorizeMethod(read, "lattices", "window.place")).toContain("scope_denied");
  expect(authorizeMethod(grantsForScope("lattices", "drive"), "lattices", "new.execute")).toContain("method_denied");
  expect(authorizeMethod(read, "speech", "speech.status")).toContain("scope_denied");
  expect(authorizeMethod(["action:status"], "action", "status")).toBeNull();
  expect(() => requestedGrants({ grants: ["action:*"], scope: "drive" })).toThrow();
  expect(() => requestedGrants({ grants: ["lattices:clients.approve"] })).toThrow();
  expect(() => requestedGrants({ scope: "admin" })).toThrow();
  expect(isTailnetAddress("0.0.0.0")).toBe(false);
  expect(isTailnetAddress("192.168.1.9")).toBe(false);
  expect(isTailnetAddress("100.64.1.9")).toBe(true);
  for (const method of ["clients.approve", "bridge.pairing.approve", "actions.execute", "intents.run", "browser.executeJavascript", "capture.live"]) {
    expect(authorizeMethod(grantsForScope("lattices", "drive"), "lattices", method)).toContain("method_denied");
  }
  expect(authorizeMethod(grantsForScope("lattices", "act"), "lattices", "layers.activate")).toContain("scope_denied");
  // Reading a monitor's input is harmless; switching it takes the screen away from another host.
  expect(authorizeMethod(read, "lattices", "display.input.get")).toBeNull();
  expect(authorizeMethod(grantsForScope("lattices", "act"), "lattices", "display.input.set")).toContain("scope_denied");
  expect(authorizeMethod(grantsForScope("lattices", "drive"), "lattices", "display.input.set")).toBeNull();
  for (const method of ["drive.begin", "drive.touch", "drive.release", "workspace.dragFile", "workspace.cancelOperation"]) {
    // A trust record from an earlier gateway must not revive unsupported leases.
    expect(authorizeMethod([`action:${method}`], "action", method)).toContain("method_denied");
    expect(() => requestedGrants({ grants: [`action:${method}`] })).toThrow();
  }
  expect(authorizeMethod(["action:drive.status"], "action", "drive.status")).toBeNull();
});

test("Canvas aliases normalize to exact existing Blink grants before approval", () => {
  expect(canonicalProduct("canvas")).toBe("blink");
  expect(canonicalProduct("blink")).toBe("blink");
  expect(canonicalProduct("Canvas")).toBeNull();
  expect(requestedGrants({ grants: ["canvas:notes.list", "blink:notes.list"] })).toEqual(["blink:notes.list"]);
  expect(validGrant("blink:notes.list")).toBe(true);
  expect(validGrant("canvas:notes.list")).toBe(false); // aliases never enter stored records
  for (const grant of ["canvas:*", "canvas:notes.delete", "canvas:notes.list:", "canvas:speech.status", "canvas:notes.list:extra"]) {
    expect(() => requestedGrants({ grants: [grant] })).toThrow("Invalid exact");
  }
  expect(authorizeMethod(["blink:notes.list"], canonicalProduct("canvas")!, "notes.list")).toBeNull();
  expect(authorizeMethod(["blink:notes.list"], canonicalProduct("canvas")!, "notes.present")).toContain("scope_denied");
  expect(authorizeMethod(["lattices:windows.list"], canonicalProduct("canvas")!, "notes.list")).toContain("scope_denied");
});

test("Canvas socket paths match native home expansion and preserve the legacy directory", () => {
  const home = "/fixture/user";
  expect(canvasSocketPath({}, home)).toBe("/fixture/user/Library/Application Support/Blink/blink.sock");
  expect(canvasSocketPath({ CANVAS_HOME: "~/scratch", BLINK_HOME: "/unused" }, home)).toBe("/fixture/user/scratch/blink.sock");
  expect(canvasSocketPath({ CANVAS_HOME: "~" }, home)).toBe("/fixture/user/blink.sock");
  expect(canvasSocketPath({ CANVAS_HOME: "", BLINK_HOME: "~/old" }, home)).toBe("/fixture/user/old/blink.sock");
  expect(canvasSocketPath({ CANVAS_HOME: "/absolute", BLINK_HOME: "~/old" }, home)).toBe("/absolute/blink.sock");
});

async function fixture(run: (f: any) => Promise<void>) {
  const root = mkdtempSync(join(tmpdir(), "gateway-test-"));
  const previous = process.env.LATTICES_RUNTIME_DIR;
  process.env.LATTICES_RUNTIME_DIR = join(root, "run");
  const local = localEndpoint("lattices");
  const router = new Router(() => new Set());
  const calls: string[] = [];
  const stalled = { started: false, aborted: false };
  router.register({ method: "windows.list", access: "read", description: "fixture", returns: "", handler: () => { calls.push("windows.list"); return [{ title: "private fixture" }]; } });
  router.register({ method: "windows.place", access: "mutate", description: "fixture", returns: "", handler: () => { calls.push("windows.place"); return { ok: true }; } });
  router.register({ method: "windows.get", access: "read", description: "fixture", returns: "", handler: () => new Promise(resolve => {
    stalled.started = true;
    currentRequestContext()?.signal?.addEventListener("abort", () => { stalled.aborted = true; resolve(null); }, { once: true });
  }) });
  await prepareSocket(local.socketPath!);
  const product = serve({ socketPath: local.socketPath!, tokenFile: local.tokenFile!, router, log: () => {} });
  const approvals = new PairingApprovals(2000, false);
  const pairing = new GatewayPairing("fixture", join(root, "state"), approvals);
  const allowedHosts = new Set<string>();
  const admin = localEndpoint("gateway");
  const audit: unknown[] = [];
  const admission: { allowed: boolean; hold?: Promise<void>; count: number } = { allowed: true, count: 0 };
  const handlers = gatewayHandlers({ pairing, allowedHosts, policy: { allowUsers: ["owner"], allowTags: [] }, localToken: privateToken(admin.tokenFile!),
    identify: async () => { admission.count++; await admission.hold; return admission.allowed ? { user: "owner", node: "test-client" } : null; }, audit: record => audit.push(record), shutdown: () => {},
  });
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: handlers.fetchRemote, websocket: handlers.websocket });
  const localServer = Bun.serve({ unix: admin.socketPath!, fetch: handlers.fetchLocal, websocket: handlers.websocket });
  const { protectSocket } = await import("../../host-linux/src/private-ipc.ts"); const cleanupAdmin = protectSocket(admin.socketPath!);
  const authority = `127.0.0.1:${server.port}`;
  allowedHosts.add(authority);
  const url = `ws://${authority}`;
  const sockets: WebSocket[] = [];
  const connect = async (headers?: Record<string, string>) => { const socket = await open(url, headers); sockets.push(socket); return socket; };
  const key = generateKeyPairSync("x25519");
  const clientID = crypto.randomUUID();
  const signed = () => {
    const timestamp = new Date().toISOString(), nonce = randomBytes(16).toString("hex");
    const signing = deriveKeys(key.privateKey, publicKeyFromBase64(pairing.security.publicKeyBase64)!).signing;
    return { [HEADERS.deviceID]: clientID, [HEADERS.timestamp]: timestamp, [HEADERS.nonce]: nonce, [HEADERS.signature]: sign(signing, canonicalRequest("GET", "/", clientID, timestamp, nonce, Buffer.alloc(0))) };
  };
  const pair = async (grants?: string[], identity = key) => {
    const socket = await connect();
    const response = rpc(socket, "clients.pair", { clientID, clientName: "test-client", platform: "test", publicKey: rawPublicKey(identity.publicKey).toString("base64"), ...(grants ? { grants } : { scope: "read" }) });
    await waitFor(() => approvals.list().length > 0);
    await daemonCallTo(admin, "clients.approve", { clientID });
    const reply = await response; socket.close(); expect(reply.error).toBeNull(); return reply.result;
  };
  try { await run({ root, local, admin, pairing, approvals, product, authority, url, connect, signed, pair, clientID, audit, calls, stalled, admission }); }
  finally { for (const socket of sockets) socket.close(); handlers.stop(); server.stop(true); localServer.stop(true); cleanupAdmin(); product.stop(); rmSync(root, { recursive: true, force: true }); if (previous === undefined) delete process.env.LATTICES_RUNTIME_DIR; else process.env.LATTICES_RUNTIME_DIR = previous; }
}

test("actual gateway sockets reject origins, forged hosts, unpaired, bad signatures and insufficient grants; route only private product IPC", () => fixture(async f => {
  expect(lstatSync(f.local.socketPath).mode & 0o777).toBe(0o600);
  expect(lstatSync(join(f.root, "run")).mode & 0o777).toBe(0o700);
  expect((await fetch(`http://${f.authority}`, { headers: { origin: "https://evil.example" } })).status).toBe(403);
  expect((await fetch(`http://${f.authority}`, { headers: { host: "evil.example" } })).status).toBe(403);
  const unpaired = await f.connect();
  expect((await rpc(unpaired, "windows.list")).error).toContain("pairing_required");
  await f.pair();
  const bad = f.signed(); bad[HEADERS.signature] = "forged";
  expect((await fetch(`http://${f.authority}`, { headers: bad })).status).toBe(401);
  const headers = f.signed(); const paired = await f.connect(headers);
  expect((await fetch(`http://${f.authority}`, { headers })).status).toBe(401); // replay
  expect((await rpc(paired, "windows.list")).result).toEqual([{ title: "private fixture" }]);
  expect((await rpc(paired, "window.place")).error).toContain("scope_denied");
  expect((await rpc(paired, "gateway.call", { product: "action", method: "status" })).error).toContain("scope_denied");
  for (const method of ["drive.begin", "drive.touch", "drive.release", "workspace.dragFile", "workspace.cancelOperation"]) {
    f.pairing.client(f.clientID).capabilities.push(`action:${method}`);
    expect((await rpc(paired, "gateway.call", { product: "action", method })).error).toContain("method_denied");
  }
  expect((await rpc(paired, "unknown.execute")).error).toContain("method_denied");
  expect((await rpc(paired, "gateway.call", { product: "../../evil", method: "windows.list" })).error).toContain("Invalid product");
  expect((await rpc(paired, "clients.approve", { clientID: "evil" })).error).toContain("method_denied");
  expect(f.calls).toEqual(["windows.list"]);
}), 8000);

test("revocation closes active gateway connections and refuses a fresh signed connection", () => fixture(async f => {
  await f.pair(); const socket = await f.connect(f.signed());
  const closed = new Promise(resolve => socket.addEventListener("close", resolve, { once: true }));
  socket.send(JSON.stringify({ id: "pending", method: "windows.get" }));
  await waitFor(() => f.stalled.started);
  await daemonCallTo(f.admin, "clients.revoke", { clientID: f.clientID });
  await closed;
  await waitFor(() => f.stalled.aborted);
  expect((await fetch(`http://${f.authority}`, { headers: f.signed() })).status).toBe(403);
}));

test("signed Canvas and legacy Blink calls use the same private socket and exact stored permission", () => fixture(async f => {
  const previousCanvas = process.env.CANVAS_HOME, previousBlink = process.env.BLINK_HOME;
  process.env.CANVAS_HOME = f.root;
  process.env.BLINK_HOME = join(f.root, "unused-legacy-home");
  const socketPath = join(f.root, "blink.sock");
  const calls: string[] = [];
  const server = createServer(socket => socket.once("data", data => {
    const request = JSON.parse(data.toString()); calls.push(request.method);
    socket.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: [{ title: "Existing note" }] }) + "\n");
  }));
  try {
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); });
    chmodSync(socketPath, 0o600);
    await f.pair(["canvas:notes.list", "blink:notes.list"]);
    expect(f.pairing.client(f.clientID).capabilities).toEqual(["blink:notes.list"]);
    const socket = await f.connect(f.signed());
    for (const product of ["canvas", "blink"]) {
      expect((await rpc(socket, "gateway.call", { product, method: "notes.list" })).result).toEqual([{ title: "Existing note" }]);
      expect((await rpc(socket, "gateway.call", { product, method: "notes.present" })).error).toContain("scope_denied");
      expect((await rpc(socket, "gateway.call", { product, method: "notes.delete" })).error).toContain("method_denied");
    }
    expect((await rpc(socket, "gateway.call", { product: "action", method: "status" })).error).toContain("scope_denied");
    expect(calls).toEqual(["notes.list", "notes.list"]);
    const successes = f.audit.filter((event: any) => event.method === "notes.list" && event.disposition === "success");
    expect(successes.map((event: any) => event.product)).toEqual(["blink", "blink"]);
    expect(f.pairing.client(f.clientID).capabilities).toEqual(["blink:notes.list"]);
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
    if (previousCanvas === undefined) delete process.env.CANVAS_HOME; else process.env.CANVAS_HOME = previousCanvas;
    if (previousBlink === undefined) delete process.env.BLINK_HOME; else process.env.BLINK_HOME = previousBlink;
  }
}));

test("approved replacement keys close connections authenticated by the former key", () => fixture(async f => {
  await f.pair(); const socket = await f.connect(f.signed());
  const closed = new Promise(resolve => socket.addEventListener("close", resolve, { once: true }));
  await f.pair(undefined, generateKeyPairSync("x25519"));
  await closed;
  expect((await fetch(`http://${f.authority}`, { headers: f.signed() })).status).toBe(401);
}));

test("disconnect cancels the outstanding private product request", () => fixture(async f => {
  await f.pair(); const socket = await f.connect(f.signed());
  socket.send(JSON.stringify({ id: "pending", method: "windows.get" }));
  await waitFor(() => f.stalled.started);
  socket.close(); await waitFor(() => f.stalled.aborted);
}));

test("identity denial and pending admission limits cannot occupy the local admin channel", () => fixture(async f => {
  f.admission.allowed = false;
  expect((await fetch(`http://${f.authority}`)).status).toBe(403);
  f.admission.allowed = true;
  let release!: () => void;
  f.admission.hold = new Promise<void>(resolve => { release = resolve; });
  const requests = Array.from({ length: 40 }, () => fetch(`http://${f.authority}`));
  try {
    await waitFor(() => f.admission.count === 33);
    expect((await daemonCallTo(f.admin, "gateway.status") as { running: boolean }).running).toBe(true);
  } finally { release(); }
  const statuses = await Promise.all(requests.map(async request => (await request).status));
  expect(statuses.filter(status => status === 429)).toHaveLength(8);
}));

test("companion HTTP and binary visit relay retain inner signatures over private IPC", () => fixture(async f => {
  const endpoint = localEndpoint("companion");
  const token = privateToken(endpoint.tokenFile!);
  const seen: string[] = [];
  const companion = Bun.serve({ unix: endpoint.socketPath!, fetch(req, server) {
    if (req.headers.get("x-lattices-token") !== token || req.headers.get("host") !== "localhost") return new Response("no", { status: 403 });
    const path = new URL(req.url).pathname; seen.push(path);
    if (req.headers.get(HEADERS.signature) !== "inner-signature") return new Response("bad signature", { status: 401 });
    if (path === "/visit") { if (server.upgrade(req)) return; return new Response("upgrade", { status: 426 }); }
    return Response.json({ path, device: req.headers.get(HEADERS.deviceID) });
  }, websocket: { open(ws) { ws.send(new Uint8Array([1, 2, 3])); }, message(ws, data) { ws.send(data); } } });
  const { protectSocket } = await import("../../host-linux/src/private-ipc.ts"); const remove = protectSocket(endpoint.socketPath!);
  try {
    const headers = { [HEADERS.signature]: "inner-signature", [HEADERS.deviceID]: "companion-test" };
    const response = await fetch(`http://${f.authority}/deck/snapshot`, { headers });
    expect(await response.json()).toEqual({ path: "/deck/snapshot", device: "companion-test" });
    expect((await fetch(`http://${f.authority}/deck/snapshot`)).status).toBe(401);
    expect((await fetch(`http://${f.authority}/arbitrary/path`, { headers })).status).toBe(404);
    const socket = new WS(`${f.url}/visit`, { headers });
    socket.binaryType = "arraybuffer";
    const initial = new Promise<ArrayBuffer>(resolve => { socket.onmessage = event => resolve(event.data); });
    await new Promise<void>((resolve, reject) => { socket.onopen = () => resolve(); socket.onerror = () => reject(new Error("Rejected visit")); });
    expect(new Uint8Array(await initial)).toEqual(new Uint8Array([1, 2, 3]));
    const returned = new Promise<ArrayBuffer>(resolve => { socket.onmessage = event => resolve(event.data); });
    const bytes = new Uint8Array([9, 0, 255, 3]); socket.send(bytes);
    expect(new Uint8Array(await returned)).toEqual(bytes);
    socket.close();
    await expect(open(`${f.url}/visit`, { [HEADERS.signature]: "bad" })).rejects.toThrow("rejected");
    expect(seen).toContain("/visit");
  } finally { companion.stop(true); remove(); }
}));

test("explicit product grants report unavailable without starting product and filter real core events", () => fixture(async f => {
  await f.pair(["speech:speech.status", "lattices:events.subscribe", "lattices:events.unsubscribe", "lattices:windows.list"]);
  const socket = await f.connect(f.signed());
  expect((await rpc(socket, "gateway.call", { product: "speech", method: "speech.status" })).error).toContain("product_unavailable");
  expect((await rpc(socket, "events.subscribe", { events: ["spaces.changed"] })).error).toContain("scope_denied");
  expect((await rpc(socket, "events.subscribe", { events: ["windows.changed"] })).result.events).toEqual(["windows.changed"]);
  await waitFor(() => f.product.clientCount() > 0);
  const received = new Promise<any>(resolve => socket.addEventListener("message", (event: MessageEvent) => { const data = JSON.parse(String(event.data)); if (data.event) resolve(data); }, { once: true }));
  f.product.broadcast("windows.changed", { test: true });
  expect((await received).event).toBe("windows.changed");
}));

test("private Linux host has no TCP listener and refuses missing token or browser Origin", async () => {
  const root = mkdtempSync(join(tmpdir(), "private-host-"));
  const endpoint = { host: "localhost", port: 0, socketPath: join(root, "lattices.sock"), tokenFile: join(root, "lattices.token") };
  const server = serve({ ...endpoint, tokenFile: endpoint.tokenFile, router: new Router(() => new Set()), log: () => {} });
  try {
    expect(server.ports).toEqual([undefined]);
    expect((await fetch("http://localhost", { unix: endpoint.socketPath })).status).toBe(403);
    expect((await fetch("http://localhost", { unix: endpoint.socketPath, headers: { origin: "null", "x-lattices-token": privateToken(endpoint.tokenFile) } })).status).toBe(403);
    expect((await fetch("http://localhost", { unix: endpoint.socketPath, headers: { "x-lattices-token": privateToken(endpoint.tokenFile) } })).status).toBe(200);
  } finally { server.stop(); rmSync(root, { recursive: true, force: true }); }
});

test("gateway start refuses arbitrary network interfaces before creating any listener", async () => {
  const root = mkdtempSync(join(tmpdir(), "gateway-denied-"));
  try { await expect(startGateway({ address: "0.0.0.0", port: 9399, name: "fixture", policy: { allowUsers: [], allowTags: [] }, stateDir: root, verifiedIPs: ["0.0.0.0"] })).rejects.toThrow("verified Tailscale"); }
  finally { rmSync(root, { recursive: true, force: true }); }
});

test("Blink private routing preserves a UTF-8 scalar split across socket reads", async () => {
  const root = mkdtempSync(join(tmpdir(), "gateway-blink-"));
  const previous = process.env.BLINK_HOME;
  const previousCanvas = process.env.CANVAS_HOME;
  delete process.env.CANVAS_HOME;
  process.env.BLINK_HOME = root;
  const socketPath = join(root, "blink.sock");
  const server = createServer(socket => {
    socket.once("data", request => {
      const { id } = JSON.parse(request.toString());
      const response = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id, result: { text: "Note 🌍 café" } }) + "\n");
      const split = response.indexOf(Buffer.from("🌍")) + 2;
      socket.write(response.subarray(0, split));
      setTimeout(() => socket.end(response.subarray(split)), 20);
    });
  });
  try {
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); });
    chmodSync(socketPath, 0o600);
    expect(await callProduct("blink", "notes.get", { id: "fixture" }, 2000, new AbortController().signal)).toEqual({ text: "Note 🌍 café" });
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
    rmSync(root, { recursive: true, force: true });
    if (previous === undefined) delete process.env.BLINK_HOME; else process.env.BLINK_HOME = previous;
    if (previousCanvas === undefined) delete process.env.CANVAS_HOME; else process.env.CANVAS_HOME = previousCanvas;
  }
});

test("private token and pairing key reject linked files", () => {
  const root = mkdtempSync(join(tmpdir(), "gateway-files-"));
  try {
    const token = join(root, "token"); privateToken(token);
    linkSync(token, join(root, "linked-token"));
    expect(() => privateToken(token)).toThrow("Unsafe IPC token");
    const key = join(root, "key.json"); loadOrCreateBridgeKey(key);
    symlinkSync(key, join(root, "key-link.json"));
    expect(() => loadOrCreateBridgeKey(join(root, "key-link.json"))).toThrow();
    linkSync(key, join(root, "key-hardlink.json"));
    expect(() => loadOrCreateBridgeKey(key)).toThrow("Unsafe pairing state");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("audit metadata has a private bounded file and rejects linked targets", () => {
  const root = mkdtempSync(join(tmpdir(), "gateway-audit-"));
  try {
    const path = join(root, "audit.jsonl");
    for (let i = 0; i < 20; i++) appendAudit(path, { method: "windows.list", disposition: "success" }, 128);
    expect(lstatSync(path).size).toBeLessThanOrEqual(128);
    expect(lstatSync(path).mode & 0o777).toBe(0o600);
    symlinkSync(path, join(root, "audit-link.jsonl"));
    expect(() => appendAudit(join(root, "audit-link.jsonl"), {})).toThrow();
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("capture.stream keeps one private lattices socket per client and relays its binary frames", () => fixture(async f => {
  f.product.stop();
  const token = privateToken(f.local.tokenFile!);
  const daemon = { opened: 0, closed: 0, acks: 0, socket: undefined as any };
  const fake = Bun.serve({ unix: f.local.socketPath!, fetch(req, server) {
    if (req.headers.get("x-lattices-token") !== token) return new Response("no", { status: 403 });
    if (server.upgrade(req)) return; return new Response("upgrade", { status: 426 });
  }, websocket: {
    open(ws) { daemon.opened++; daemon.socket ??= ws; },
    close(ws) { if (ws === daemon.socket) daemon.closed++; },
    message(ws, raw) {
      const request = JSON.parse(String(raw));
      const reply = (result: unknown, error: string | null = null) => ws.send(JSON.stringify({ id: request.id, result, error }));
      if (request.method === "capture.stream.start") { reply({ streamId: 7, codec: "h264", width: 4, height: 2 }); ws.send(new Uint8Array([0x4c, 0x56, 0x46, 0x31, 7])); return; }
      if (request.method === "capture.stream.ack") { daemon.acks++; reply({ ok: true }); return; }
      reply({ ok: true });
    },
  } });
  const { protectSocket } = await import("../../host-linux/src/private-ipc.ts"); const remove = protectSocket(f.local.socketPath!);
  try {
    await f.pair(["lattices:capture.stream.start", "lattices:capture.stream.ack", "lattices:capture.stream.stop", "lattices:windows.list"]);
    const socket = await f.connect(f.signed());
    socket.binaryType = "arraybuffer";
    expect((await rpc(socket, "capture.stream.ack", { streamId: 7, seq: 1 })).error).toContain("Unknown stream");
    const frame = new Promise<ArrayBuffer>(resolve => socket.addEventListener("message", (event: MessageEvent) => { if (typeof event.data !== "string") resolve(event.data); }));
    expect((await rpc(socket, "capture.stream.start", { displayIndex: 0 })).result.streamId).toBe(7);
    expect(new Uint8Array(await frame)).toEqual(new Uint8Array([0x4c, 0x56, 0x46, 0x31, 7]));
    // Acks bypass the 600/min request budget.
    for (let seq = 1; seq <= 700; seq++) socket.send(JSON.stringify({ id: `a${seq}`, method: "capture.stream.ack", params: { streamId: 7, seq } }));
    await waitFor(() => daemon.acks === 700);
    expect((await rpc(socket, "windows.list")).error).toBeNull();
    const ended = new Promise<any>(resolve => socket.addEventListener("message", (event: MessageEvent) => { if (typeof event.data === "string" && JSON.parse(event.data).event) resolve(JSON.parse(event.data)); }));
    daemon.socket.send(JSON.stringify({ event: "windows.changed", data: {} }));
    daemon.socket.send(JSON.stringify({ event: "capture.stream.ended", data: { streamId: 7, reason: "ack-timeout" } }));
    expect(await ended).toEqual({ event: "capture.stream.ended", data: { streamId: 7, reason: "ack-timeout" } });
    expect(daemon.opened).toBe(2); // the stream socket, then one per-request call
    socket.close();
    await waitFor(() => daemon.closed === 1);
  } finally { fake.stop(true); remove(); }
}), 8000);

test("screen and shell are separate scopes; shorthands keep their former reach", () => {
  const read = grantsForScope("lattices", "read");
  for (const method of ["capture.still", "capture.screenshot", "terminals.capture", "ocr.search", "computer.observe", "files.read"]) expect(read).not.toContain(`lattices:${method}`);
  expect(read).toContain("lattices:windows.list");
  const act = grantsForScope("lattices", "act");
  expect(act).toContain("lattices:capture.still");
  expect(act).toContain("lattices:windows.place");
  expect(act).not.toContain("lattices:apps.open");
  const drive = grantsForScope("lattices", "drive");
  for (const method of ["computer.click", "computer.typeText", "apps.open", "sessions.launch", "capture.still"]) expect(drive).toContain(`lattices:${method}`);
  expect(requestedGrants({ scope: "read", scopes: ["screen"] }).sort()).toEqual(grantsForScope("lattices", "read", ["screen"]).sort());
  expect(requestedGrants({ scope: "read", scopes: ["screen"] })).toContain("lattices:capture.still");
  expect(requestedGrants({ scope: "read", scopes: ["shell"] })).toContain("lattices:computer.typeText");
  expect(requestedGrants({ scope: "read", scopes: ["shell"] })).not.toContain("lattices:capture.still");
  expect(() => requestedGrants({ scope: "read", scopes: ["admin"] })).toThrow("Invalid pairing scopes");
  expect(() => requestedGrants({ scope: "read", scopes: "screen" })).toThrow("Invalid pairing scopes");
  expect(scopesHeld(grantsForScope("lattices", "read"))).toEqual(["read"]);
  expect(scopesHeld(grantsForScope("lattices", "act"))).toEqual(["read", "screen", "act"]);
  expect(scopesHeld(grantsForScope("lattices", "drive"))).toEqual(["read", "screen", "act", "drive", "shell"]);
  expect(scopesHeld(["lattices:windows.list"])).toEqual([]);
  // A client stored with grants from before the split keeps every exact method it holds.
  const legacyRead = [...read, "lattices:capture.still", "lattices:terminals.capture"];
  expect(authorizeMethod(legacyRead, "lattices", "capture.still")).toBeNull();
  expect(authorizeMethod(legacyRead, "lattices", "terminals.capture")).toBeNull();
  expect(authorizeMethod(read, "lattices", "capture.still")).toContain("scope_denied");
});

test("pairing limits: one prompt per machine, joined repeats, cooldown only after a denial", async () => {
  let now = 0;
  const limits = new PairingLimits<string>(PAIRING_COOLDOWN_MS, () => now);
  let answer!: (value: string) => void;
  let started = 0;
  const start = () => { started++; return new Promise<string>(resolve => { answer = resolve; }); };
  const first = limits.enter("gateway", "node:mini", "device-a", start);
  const repeat = limits.enter("gateway", "node:mini", "device-a", start);
  expect(started).toBe(1);
  expect(() => limits.enter("gateway", "node:mini", "device-b", start)).toThrow("pairing_pending");
  const other = limits.enter("gateway", "node:air", "device-b", async () => "other");
  expect(await other.result).toBe("other");
  expect(limits.pendingIdentity("device-a")).toBe("node:mini");
  expect(repeat.leave()).toBe(false);
  expect(first.leave()).toBe(true);
  answer("timed out");
  expect(await first.result).toBe("timed out");
  // A timeout starts no cooldown.
  expect(await limits.enter("gateway", "node:mini", "device-b", async () => "again").result).toBe("again");
  limits.deny("node:mini");
  expect(() => limits.enter("gateway", "node:mini", "device-a", start)).toThrow("pairing_cooldown");
  expect(() => limits.enter("companion", "node:mini", "device-a", start)).toThrow("try again in 5 min");
  now += PAIRING_COOLDOWN_MS + 1;
  expect(await limits.enter("gateway", "node:mini", "device-a", async () => "after").result).toBe("after");
  expect(pairingIdentity({ user: "u", node: "Mini" } as any, "100.64.0.1")).toBe("node:mini");
  expect(pairingIdentity({ user: "u", node: "unknown" } as any, "100.64.0.1")).toBe("ip:100.64.0.1");
});

test("the gateway holds one pairing prompt per machine and cools down after an operator denial", () => fixture(async f => {
  const request = async (clientID: string) => {
    const socket = await f.connect();
    const key = generateKeyPairSync("x25519");
    return { socket, reply: rpc(socket, "clients.pair", { clientID, clientName: "test-client", platform: "test", publicKey: rawPublicKey(key.publicKey).toString("base64"), scope: "read" }) };
  };
  const first = await request(f.clientID);
  await waitFor(() => f.approvals.list().length > 0);
  const second = await request(crypto.randomUUID());
  expect((await second.reply).error).toContain("pairing_pending");
  expect(f.approvals.list()).toHaveLength(1);
  await daemonCallTo(f.admin, "clients.deny", { clientID: f.clientID });
  await first.reply;
  const third = await request(crypto.randomUUID());
  expect((await third.reply).error).toContain("pairing_cooldown");
  expect(f.approvals.list()).toHaveLength(0);
}), 8000);
