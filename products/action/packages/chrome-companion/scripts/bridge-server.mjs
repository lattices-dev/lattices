#!/usr/bin/env bun
import { chmodSync, lstatSync, unlinkSync } from "node:fs";
import { createConnection } from "node:net";
import { chromeCompanionSocket, chromeCompanionToken } from "../../runtime/src/chrome-companion-ipc.ts";
import { ensurePrivateToken, tokenMatches } from "../../runtime/src/local-security.ts";

const token = ensurePrivateToken(chromeCompanionToken());
const socketPath = chromeCompanionSocket();
try {
  const info = lstatSync(socketPath);
  if (!info.isSocket() || info.uid !== process.getuid()) throw new Error("Refusing to replace non-owned Chrome companion endpoint");
  const active = await new Promise(resolve => {
    const socket = createConnection(socketPath);
    socket.once("connect", () => { socket.destroy(); resolve(true); });
    socket.once("error", error => { socket.destroy(); resolve(error.code !== "ECONNREFUSED" && error.code !== "ENOENT"); });
    socket.setTimeout(500, () => { socket.destroy(); resolve(true); });
  });
  if (active) throw new Error("Chrome companion already running");
  unlinkSync(socketPath);
} catch (error) { if (error.code !== "ENOENT") throw error; }
const pending = new Map();
let extensionSocket = null;
const server = Bun.serve({
  unix: socketPath,
  maxRequestBodySize: 1_048_576,
  idleTimeout: 10,
  async fetch(request, server) {
    if (request.headers.has("origin") || request.headers.get("host") !== "localhost" || !tokenMatches(request.headers.get("x-lattices-token"), token)) return json({ ok: false, error: "Authenticated private IPC required" }, 401);
    const url = new URL(request.url);
    if (url.pathname === "/chrome-companion") {
      if (extensionSocket) return json({ ok: false, error: "Companion extension already connected" }, 409);
      if (server.upgrade(request)) return;
      return json({ ok: false, error: "WebSocket upgrade required" }, 400);
    }
    if (url.pathname === "/health" && request.method === "GET") return json({ ok: true, connected: extensionSocket?.readyState === WebSocket.OPEN, pending: pending.size });
    if (url.pathname === "/rpc" && request.method === "POST") {
      if (extensionSocket?.readyState !== WebSocket.OPEN) return json({ ok: false, error: "Action Chrome Companion native messaging host is not connected." }, 503);
      if (pending.size >= 64) return json({ ok: false, error: "Companion busy" }, 429);
      let message; try { message = await request.json(); } catch { return json({ ok: false, error: "Invalid JSON" }, 400); }
      if (typeof message?.method !== "string") return json({ ok: false, error: "Missing method" }, 400);
      const id = crypto.randomUUID();
      const response = await new Promise(resolve => {
        const timer = setTimeout(() => { pending.delete(id); resolve({ ok: false, error: "Extension response timed out" }); }, 30_000);
        pending.set(id, { resolve: response => { clearTimeout(timer); resolve(response); } });
        extensionSocket.send(JSON.stringify({ id, message }));
      });
      return json(response, response.ok === false ? 500 : 200);
    }
    return json({ ok: false, error: "Not found" }, 404);
  },
  websocket: {
    maxPayloadLength: 1_048_576,
    open(socket) { extensionSocket = socket; },
    message(socket, data) {
      if (socket !== extensionSocket) return;
      let payload; try { payload = JSON.parse(String(data)); } catch { socket.close(1007); return; }
      const waiter = pending.get(payload.id);
      if (waiter) { pending.delete(payload.id); waiter.resolve(payload.response); }
    },
    close(socket) {
      if (socket === extensionSocket) {
        extensionSocket = null;
        for (const waiter of pending.values()) waiter.resolve({ ok: false, error: "Extension disconnected" });
        pending.clear();
      }
    },
  },
});
chmodSync(socketPath, 0o600);
console.log(`[bridge] listening on private socket ${socketPath}`);
function json(value, status = 200) { return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } }); }
