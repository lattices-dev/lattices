import { privateWebSocket } from "../../host-linux/src/private-ipc.ts";
import { createConnection } from "node:net";
import { join } from "node:path";
import { homedir } from "node:os";
import { daemonCallTo } from "../../desktop-client/daemon-client.ts";
import { localEndpoint, readLocalToken, validateLocalSocket } from "../../desktop-client/local-ipc.ts";
import type { Product } from "./policy.ts";

export type ProductCall = (product: Product, method: string, params: Record<string, unknown>, timeoutMs: number, signal: AbortSignal) => Promise<unknown>;

/** Match BlinkPaths.home for the canonical and legacy per-user overrides. */
export function canvasSocketPath(environment: Record<string, string | undefined> = process.env, home = homedir()): string {
  const override = environment.CANVAS_HOME || environment.BLINK_HOME;
  const directory = !override ? join(home, "Library", "Application Support", "Blink")
    : override === "~" ? home
    : override.startsWith("~/") ? join(home, override.slice(2)) : override;
  return join(directory, "blink.sock");
}

export const callProduct: ProductCall = async (product, method, params, timeoutMs, signal) => {
  try {
    if (product === "blink") return await callBlink(method, params, timeoutMs, signal);
    const endpoint = localEndpoint(product);
    return await daemonCallTo(endpoint, method, params, timeoutMs, signal);
  } catch (error) {
    if (["ENOENT", "ECONNREFUSED"].includes((error as NodeJS.ErrnoException).code ?? "")) throw new Error(`product_unavailable: ${product} is not running`);
    throw error;
  }
};

function callBlink(method: string, params: Record<string, unknown>, timeoutMs: number, signal: AbortSignal): Promise<unknown> {
  // Environment belongs to the per-user service, never to a remote request.
  const socketPath = canvasSocketPath();
  validateLocalSocket(socketPath);
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    const id = crypto.randomUUID();
    let input = Buffer.alloc(0), settled = false;
    const finish = (error?: Error, result?: unknown) => {
      if (settled) return;
      settled = true; clearTimeout(timer); signal.removeEventListener("abort", abort); socket.destroy();
      if (error) reject(error); else resolve(result);
    };
    const abort = () => finish(new Error("Request cancelled; action outcome may be uncertain"));
    const timer = setTimeout(abort, timeoutMs);
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) { abort(); return; }
    socket.on("connect", () => socket.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n"));
    socket.on("error", finish);
    socket.on("close", () => finish(new Error("Blink connection closed; action outcome may be uncertain")));
    socket.on("data", chunk => {
      const bytes = typeof chunk === "string" ? Buffer.from(chunk) : chunk;
      if (input.length + bytes.length > 8 * 1024 * 1024) { finish(new Error("Blink reply too large")); return; }
      input = Buffer.concat([input, bytes]);
      while (input.includes(0x0a)) {
        // Decode a complete frame: a socket read may split a UTF-8 scalar.
        const end = input.indexOf(0x0a), line = input.subarray(0, end).toString("utf8"); input = input.subarray(end + 1);
        try {
          const response = JSON.parse(line);
          if (response.id !== id) continue;
          finish(response.error ? new Error(typeof response.error === "string" ? response.error : response.error.message) : undefined, response.result);
          return;
        } catch { finish(new Error("Invalid Blink reply")); return; }
      }
    });
  });
}

export const COMPANION_ROUTES = new Set([
  "GET /health", "GET /deck/manifest", "POST /pairing/request", "GET /deck/snapshot",
  "POST /deck/perform", "POST /deck/trackpad", "POST /deck/preview",
]);
export async function proxyCompanion(req: Request): Promise<Response> {
  const endpoint = localEndpoint("companion");
  const path = new URL(req.url).pathname;
  if (!COMPANION_ROUTES.has(`${req.method} ${path}`)) return new Response("Unknown companion route", { status: 404 });
  try {
    validateLocalSocket(endpoint.socketPath!);
    const headers = new Headers({ "host": "localhost", "x-lattices-token": readLocalToken(endpoint.tokenFile!) });
    for (const name of ["content-type", "x-lattices-device-id", "x-lattices-timestamp", "x-lattices-nonce", "x-lattices-signature"]) {
      const value = req.headers.get(name); if (value) headers.set(name, value);
    }
    const body = req.method === "POST" ? await req.arrayBuffer() : undefined;
    if (body && body.byteLength > 512 * 1024) return new Response("Body too large", { status: 413 });
    const response = await fetch(`http://localhost${path}`, { unix: endpoint.socketPath, method: req.method, headers, body, signal: AbortSignal.any([req.signal, AbortSignal.timeout(125_000)]) });
    return new Response(response.body, { status: response.status, headers: { "content-type": response.headers.get("content-type") ?? "application/json", "cache-control": "no-store" } });
  } catch { return new Response("Companion product unavailable", { status: 503 }); }
}

/** Inner bridge performs the original /visit signature and scope check before
 * the gateway upgrades the remote connection. Binary encrypted frames remain
 * unchanged; no gateway interpretation or decryption. */
export interface CompanionVisit {
  socket: WebSocket;
  /** Frames may arrive between the private and remote upgrade handshakes. */
  attach(receive: (data: string | ArrayBuffer) => void, closed: () => void): void;
}
export async function connectCompanionVisit(req: Request): Promise<CompanionVisit> {
  const endpoint = localEndpoint("companion");
  validateLocalSocket(endpoint.socketPath!);
  const headers: Record<string, string> = { host: "localhost", "x-lattices-token": readLocalToken(endpoint.tokenFile!) };
  for (const name of ["x-lattices-device-id", "x-lattices-timestamp", "x-lattices-nonce", "x-lattices-signature"]) {
    const value = req.headers.get(name); if (value) headers[name] = value;
  }
  return new Promise((resolve, reject) => {
    const socket = privateWebSocket(endpoint.socketPath!, "/visit", headers);
    socket.binaryType = "arraybuffer";
    const pending: (string | ArrayBuffer)[] = [];
    let bytes = 0, receive: ((data: string | ArrayBuffer) => void) | undefined, closed: (() => void) | undefined;
    const finish = (error: Error) => { clearTimeout(timer); socket.close(); reject(error); closed?.(); };
    const timer = setTimeout(() => finish(new Error("Companion unavailable")), 3000);
    socket.onmessage = event => {
      const data = event.data as string | ArrayBuffer;
      if (receive) { receive(data); return; }
      bytes += typeof data === "string" ? Buffer.byteLength(data) : data.byteLength;
      if (bytes > 8 * 1024 * 1024) { finish(new Error("Companion handshake buffer exceeded")); return; }
      pending.push(data);
    };
    socket.onopen = () => {
      clearTimeout(timer);
      resolve({ socket, attach(onMessage, onClose) {
        receive = onMessage; closed = onClose;
        if (socket.readyState !== WebSocket.OPEN) { onClose(); return; }
        for (const data of pending.splice(0)) onMessage(data);
        bytes = 0;
      } });
    };
    socket.onerror = () => finish(new Error("Companion authentication failed or unavailable"));
    socket.onclose = () => finish(new Error("Companion connection closed"));
  });
}
