import type { Server, ServerWebSocket } from "bun";
import { join } from "node:path";
import { identify, type Identity, type Policy } from "../../host-linux/src/auth.ts";
import { BridgeSecurityError } from "../../host-linux/src/bridge/security.ts";
import { authorizeLocalRequest, prepareSocket, privateDirectory, privateToken, protectSocket } from "../../host-linux/src/private-ipc.ts";
import { localEndpoint } from "../../desktop-client/local-ipc.ts";
import { localEvents } from "../../desktop-client/local-events.ts";
import { GatewayPairing } from "./pairing.ts";
import { appendAudit } from "./audit.ts";
import { authorizeMethod, canonicalMethod, canonicalProduct, isTailnetAddress, validateRemoteRequest, type Product } from "./policy.ts";
import { callProduct, COMPANION_ROUTES, proxyCompanion, connectCompanionVisit, connectLatticesStream, type ProductCall, type CompanionVisit, type ProductStream, type StreamConnect } from "./products.ts";

const STREAM_METHODS = new Set(["capture.stream.start", "capture.stream.ack", "capture.stream.keyframe", "capture.stream.stop"]);

interface Connection {
  local: boolean;
  identity: Identity;
  clientID: string | null;
  clientKey?: string;
  active: Set<AbortController>;
  requests: number;
  windowStart: number;
  visit?: CompanionVisit;
  events?: { close(): void };
  eventNames?: string[];
  /** Private lattices socket holding this client's capture streams. */
  stream?: Promise<ProductStream>;
  streamIDs?: Set<number>;
}
export interface GatewayOptions {
  pairing: GatewayPairing;
  allowedHosts: Set<string>;
  policy: Policy;
  localToken: string;
  call?: ProductCall;
  streamConnect?: StreamConnect;
  identify?: (address: string, policy: Policy) => Promise<Identity | null>;
  companion?: typeof proxyCompanion;
  audit: (record: Record<string, unknown>) => void;
  shutdown: () => void;
}

/** Shared handlers make local admin and remote transport rules explicit. */
export function gatewayHandlers(options: GatewayOptions) {
  const sockets = new Set<ServerWebSocket<Connection>>();
  let admissions = 0;
  const attempts = new Map<string, { at: number; count: number }>();
  const call = options.call ?? callProduct;
  const streamConnect = options.streamConnect ?? connectLatticesStream;
  const openStream = (ws: ServerWebSocket<Connection>) => {
    const conn = ws.data;
    conn.streamIDs ??= new Set();
    const ended = (data: unknown) => { if (ws.readyState === 1) ws.send(JSON.stringify({ event: "capture.stream.ended", data })); };
    const stream = streamConnect({
      binary(data) {
        if (ws.readyState !== 1) return;
        if (ws.getBufferedAmount() > 8 * 1024 * 1024) { ws.close(1009, "Backpressure limit"); return; }
        ws.send(data);
      },
      event(name, data) {
        if (name !== "capture.stream.ended") return;
        conn.streamIDs!.delete(Number((data as { streamId?: unknown })?.streamId));
        ended(data);
      },
      closed() {
        if (conn.stream === stream) conn.stream = undefined;
        for (const streamId of conn.streamIDs!) ended({ streamId, reason: "product-closed" });
        conn.streamIDs!.clear();
      },
    });
    stream.catch(() => { if (conn.stream === stream) conn.stream = undefined; });
    return stream;
  };
  const audit = (conn: Connection, method: string, disposition: string, product?: Product) => options.audit({ at: new Date().toISOString(), client: conn.clientID, node: conn.identity.node, product, method, disposition });
  const route = async (local: boolean, req: Request, server: Server<Connection>): Promise<Response | undefined> => {
    const path = new URL(req.url).pathname;
    let identity: Identity | null;
    let clientID: string | null = null;
    let clientKey: string | undefined;
    if (local) {
      if (!authorizeLocalRequest(req, options.localToken) || path !== "/" || req.method !== "GET") return new Response("Forbidden", { status: 403 });
      identity = { user: "local", node: "localhost", local: true };
    } else {
      const denied = validateRemoteRequest(req, options.allowedHosts);
      if (denied) return new Response(denied, { status: 403 });
      const address = server.requestIP(req)?.address ?? "";
      identity = await (options.identify ?? identify)(address, options.policy);
      // Loopback never inherits the host's authority through the gateway.
      if (!identity || identity.local) return new Response("Tailnet identity required", { status: 403 });
      if (req.method === "GET" && path === "/visit") {
        try {
          const visit = await connectCompanionVisit(req);
          if (server.upgrade(req, { data: { local: false, identity, clientID: req.headers.get("x-lattices-device-id"), active: new Set(), requests: 0, windowStart: Date.now(), visit } })) return;
          visit.socket.close(); return new Response("WebSocket upgrade required", { status: 426 });
        } catch { return new Response("Companion authentication failed or unavailable", { status: 403 }); }
      }
      if (COMPANION_ROUTES.has(`${req.method} ${path}`)) {
        options.audit({ at: new Date().toISOString(), node: identity.node, method: `${req.method} ${path}`, disposition: "companion_forward" });
        return (options.companion ?? proxyCompanion)(req);
      }
      if (path !== "/" || req.method !== "GET") return new Response("Unknown route", { status: 404 });
      try { const client = options.pairing.authenticate(req.headers); clientID = client?.id ?? null; clientKey = client?.publicKey; }
      catch (error) {
        if (error instanceof BridgeSecurityError) return new Response(error.message, { status: error.status });
        return new Response("Authentication failed", { status: 403 });
      }
    }
    if (server.upgrade(req, { data: { local, identity, clientID, clientKey, active: new Set(), requests: 0, windowStart: Date.now() } })) return;
    return new Response("WebSocket upgrade required", { status: 426 });
  };
  const fetchRequest = (local: boolean) => async (req: Request, server: Server<Connection>) => {
    // Bound pending identity lookups, HTTP pairing waits, and concurrent
    // handshakes too: open-socket limits alone leave the async admission gap.
    if (!local) {
      if (admissions >= 32 || sockets.size + admissions >= 64) return new Response("Connection limit", { status: 429 });
      const now = Date.now(), address = server.requestIP(req)?.address ?? "unknown";
      const pairing = new URL(req.url).pathname === "/pairing/request";
      const upgrade = req.headers.get("upgrade")?.toLowerCase() === "websocket";
      const key = `${address}:${pairing ? "pair" : upgrade ? "upgrade" : "http"}`;
      for (const [key, value] of attempts) if (now - value.at >= 60_000) attempts.delete(key);
      let attempt = attempts.get(key);
      if (!attempt) {
        if (attempts.size >= 128) return new Response("Admission limit", { status: 429 });
        attempt = { at: now, count: 0 }; attempts.set(key, attempt);
      }
      // Existing companion trackpad HTTP calls can arrive every display frame.
      if (++attempt.count > (pairing ? 12 : upgrade ? 60 : 6000)) return new Response("Request limit", { status: 429 });
      admissions++;
    }
    try { return await route(local, req, server); }
    finally { if (!local) admissions--; }
  };
  return {
    fetchRemote: fetchRequest(false), fetchLocal: fetchRequest(true),
    websocket: {
      maxPayloadLength: 1024 * 1024,
      backpressureLimit: 64 * 1024 * 1024,
      closeOnBackpressureLimit: true,
      idleTimeout: 180,
      open(ws: ServerWebSocket<Connection>) {
        sockets.add(ws);
        if (ws.data.visit) {
          ws.data.visit.attach(data => {
            if (ws.getBufferedAmount() > 8 * 1024 * 1024) { ws.close(1009, "Backpressure limit"); return; }
            ws.send(data);
          }, () => ws.close(1000, "Companion closed"));
        }
      },
      close(ws: ServerWebSocket<Connection>) { sockets.delete(ws); ws.data.events?.close(); ws.data.visit?.socket.close(); ws.data.stream?.then(stream => stream.close(), () => {}); for (const abort of ws.data.active) abort.abort(); },
      async message(ws: ServerWebSocket<Connection>, raw: string | Buffer) {
        if (ws.data.visit) {
          if (ws.data.visit.socket.bufferedAmount > 8 * 1024 * 1024) { ws.close(1009, "Backpressure limit"); return; }
          ws.data.visit.socket.send(raw); return;
        }
        let id = "?", method = "?";
        const reply = (result: unknown, error: string | null = null) => { if (ws.readyState === 1) ws.send(JSON.stringify({ id, result: error ? null : result, error })); };
        const conn = ws.data;
        let controller: AbortController | undefined;
        try {
          const request = JSON.parse(String(raw));
          if (!request || typeof request !== "object" || Array.isArray(request)) throw new Error("Invalid request");
          id = String(request.id ?? "?"); method = request.method;
          if (id.length > 128 || typeof method !== "string" || !/^[a-zA-Z][a-zA-Z0-9_.]{0,127}$/.test(method)) throw new Error("Invalid request");
          // A live stream acks every frame; the daemon bounds those itself.
          if (method !== "capture.stream.ack") {
            if (Date.now() - conn.windowStart > 60_000) { conn.requests = 0; conn.windowStart = Date.now(); }
            if (++conn.requests > 600 || conn.active.size >= 8) throw new Error("rate_limited: gateway request limit");
          }
          const params = request.params ?? {};
          if (typeof params !== "object" || Array.isArray(params)) throw new Error("Invalid params");
          if (method === "clients.pair" && !conn.local) {
            if (conn.active.size > 0) throw new Error("Pairing already pending");
            controller = new AbortController(); conn.active.add(controller);
            const pendingID = params.clientID;
            controller.signal.addEventListener("abort", () => { if (typeof pendingID === "string") options.pairing.approvals.decide(pendingID, false); }, { once: true });
            const result = await options.pairing.pair(params, conn.identity);
            const approvedKey = typeof pendingID === "string" ? options.pairing.client(pendingID)?.publicKey : undefined;
            for (const socket of sockets) if (!socket.data.visit && socket.data.clientID === pendingID && socket.data.clientKey !== approvedKey) {
              for (const active of socket.data.active) active.abort(); socket.close(4001, "Client key changed");
            }
            audit(conn, method, result.disposition); reply(result); return;
          }
          const client = conn.clientID ? options.pairing.client(conn.clientID) : undefined;
          if (!conn.local && !client) throw new Error("pairing_required: pair this client with the gateway first");
          if (client && conn.clientKey !== client.publicKey) throw new Error("pairing_required: client key changed; reconnect");
          if (conn.local) {
            if (method === "gateway.status") { reply({ service: "lattices-gateway", running: true, transport: "tailnet", connectionCount: sockets.size, ...options.pairing.list() }); return; }
            if (method === "gateway.stop") { reply({ ok: true }); setTimeout(options.shutdown, 20); return; }
            if (method === "clients.list") { reply(options.pairing.list()); return; }
            if (["clients.approve", "clients.deny", "clients.revoke"].includes(method)) {
              if (typeof params.clientID !== "string" || params.clientID.length > 128) throw new Error("Invalid clientID");
              const clientID = params.clientID;
              const pendingDenied = method === "clients.revoke" && options.pairing.approvals.decide(clientID, false);
              const ok = method === "clients.revoke" ? options.pairing.security.revoke(clientID) || pendingDenied : options.pairing.approvals.decide(clientID, method === "clients.approve");
              if (method === "clients.revoke") for (const socket of sockets) if (socket.data.clientID === clientID) { for (const active of socket.data.active) active.abort(); socket.close(4001, "revoked"); }
              audit(conn, method, ok ? "approved" : "not_found"); reply({ ok }); return;
            }
          }
          let product: Product = "lattices", targetMethod = method, targetParams = params;
          if (method === "gateway.call") {
            const requestedProduct = canonicalProduct(params.product);
            if (!requestedProduct || typeof params.method !== "string" || params.method.length > 128) throw new Error("Invalid product or method");
            product = requestedProduct; targetMethod = params.method; targetParams = params.params ?? {};
            if (typeof targetParams !== "object" || Array.isArray(targetParams)) throw new Error("Invalid product params");
          }
          if (product === "lattices" && ["events.subscribe", "events.unsubscribe"].includes(targetMethod)) {
            const eventRequirements: Record<string, string> = {
              "windows.changed": "lattices:windows.list", "spaces.changed": "lattices:spaces.list",
              "layers.changed": "lattices:layers.list", "host.healthChanged": "lattices:daemon.status",
            };
            if (!client?.capabilities.includes(`lattices:${targetMethod}`)) throw new Error(`scope_denied: missing lattices:${targetMethod}`);
            const allowed = Object.keys(eventRequirements).filter(event => client.capabilities.includes(eventRequirements[event]!));
            const names = targetParams.events ?? allowed;
            if (!Array.isArray(names) || names.length > 32 || names.some(name => typeof name !== "string" || (name !== "*" && !allowed.includes(name)))) throw new Error("scope_denied: event requires its product read grant");
            const requested = names.includes("*") ? allowed : names;
            const selected = targetMethod === "events.unsubscribe" ? (conn.eventNames ?? []).filter(name => !requested.includes(name)) : requested;
            ws.data.events?.close(); ws.data.events = undefined; ws.data.eventNames = selected;
            if (selected.length === 0) { reply({ ok: true, events: [] }); return; }
            ws.data.events = localEvents(selected, event => {
              const current = conn.clientID ? options.pairing.client(conn.clientID) : undefined;
              const name = (event as { event?: string }).event;
              if (name && selected.includes(name) && current?.publicKey === conn.clientKey && current?.capabilities.includes(eventRequirements[name]!)) ws.send(JSON.stringify(event));
            }, error => { if (error && ws.readyState === 1) ws.send(JSON.stringify({ event: "gateway.productUnavailable", data: { product: "lattices" } })); });
            reply({ ok: true, events: selected }); return;
          }
          // Also apply allowlisting to local gateway calls: use product sockets
          // directly for local administration, never a gateway wildcard bypass.
          const denied = authorizeMethod(client?.capabilities ?? [], product, targetMethod);
          if (denied) throw new Error(denied);
          const streamMethod = product === "lattices" ? canonicalMethod(product, targetMethod) : "";
          if (STREAM_METHODS.has(streamMethod)) {
            if (streamMethod !== "capture.stream.start" && !conn.stream) throw new Error("Unknown stream");
            conn.stream ??= openStream(ws);
            const result = await (await conn.stream).call(streamMethod, targetParams, streamMethod === "capture.stream.start" ? 10_000 : 5_000);
            const streamId = Number((targetParams as { streamId?: unknown }).streamId);
            if (streamMethod === "capture.stream.start") conn.streamIDs!.add(Number((result as { streamId?: unknown })?.streamId));
            if (streamMethod === "capture.stream.stop") conn.streamIDs!.delete(streamId);
            if (streamMethod !== "capture.stream.ack") audit(conn, targetMethod, "success", product);
            reply(result); return;
          }
          const deadline = request.deadline ?? Date.now() + 30_000;
          if (!Number.isSafeInteger(deadline) || deadline <= Date.now()) throw new Error("Request deadline exceeded");
          controller = new AbortController(); conn.active.add(controller);
          const result = await call(product, targetMethod, targetParams, Math.min(deadline - Date.now(), 120_000), controller.signal);
          audit(conn, targetMethod, "success", product); reply(result);
        } catch (error) {
          const message = (error as Error).message;
          audit(conn, method, message.split(":")[0]!.slice(0, 128)); reply(null, message);
        } finally { if (controller) conn.active.delete(controller); }
      },
    },
    stop() { for (const socket of sockets) { socket.data.events?.close(); socket.data.visit?.socket.close(); socket.data.stream?.then(stream => stream.close(), () => {}); for (const active of socket.data.active) active.abort(); socket.close(1001, "Gateway stopping"); } options.pairing.stop(); },
  };
}

export async function startGateway(config: { address: string; port: number; name: string; dnsName?: string; policy: Policy; stateDir: string; verifiedIPs: string[]; onStop?: () => void }) {
  if (!isTailnetAddress(config.address) || !config.verifiedIPs.includes(config.address)) throw new Error("Gateway must bind this machine's verified Tailscale address");
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) throw new Error("Invalid gateway port");
  const local = localEndpoint("gateway");
  await prepareSocket(local.socketPath!);
  privateDirectory(config.stateDir);
  const auditPath = join(config.stateDir, "audit.jsonl");
  appendAudit(auditPath, { at: new Date().toISOString(), method: "gateway.start", disposition: "starting" });
  const pairing = new GatewayPairing(config.name, config.stateDir);
  const host = config.address.includes(":") ? `[${config.address}]` : config.address;
  const allowedHosts = new Set([`${host}:${config.port}`, `${config.name.toLowerCase()}:${config.port}`]);
  if (config.dnsName) allowedHosts.add(`${config.dnsName.toLowerCase()}:${config.port}`);
  let admin: Server<Connection> | undefined, remote: Server<Connection> | undefined;
  let removeSocket = () => {}, stopped = false;
  const stop = () => {
    if (stopped) return; stopped = true;
    handlers.stop(); remote?.stop(true); admin?.stop(true); removeSocket(); config.onStop?.();
  };
  const handlers = gatewayHandlers({ pairing, allowedHosts, policy: config.policy, localToken: privateToken(local.tokenFile!), shutdown: stop,
    audit: record => appendAudit(auditPath, record),
  });
  try {
    admin = Bun.serve({ unix: local.socketPath!, maxRequestBodySize: 1024 * 1024, fetch: handlers.fetchLocal, websocket: handlers.websocket });
    removeSocket = protectSocket(local.socketPath!);
    remote = Bun.serve({ hostname: config.address, port: config.port, maxRequestBodySize: 512 * 1024, idleTimeout: 180, fetch: handlers.fetchRemote, websocket: handlers.websocket });
    return { stop, address: config.address, port: remote.port, fingerprint: pairing.security.fingerprint };
  } catch (error) { stop(); throw error; }
}
