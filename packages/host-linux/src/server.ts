import { withRequestContext } from "./request-context.ts";
import type { ServerWebSocket } from "bun";
import { type Identity } from "./auth.ts";
import { authorizeLocalRequest, privateToken, protectSocket } from "./private-ipc.ts";
import type { Params, Request, Router } from "./router.ts";
import { STREAM_METHODS, StreamRegistry } from "./stream.ts";

interface Conn {
  identity: Identity;
  /** Events this connection asked for; null means all (the default, as on the Mac). */
  events: Set<string> | null;
  active: Set<AbortController>;
  /** capture.stream sessions this connection owns. */
  streams?: StreamRegistry;
}

/**
 * events.subscribe / events.unsubscribe act on the connection, so the server
 * answers them before the router. Returns null for any other method.
 */
export function handleSubscription(conn: Pick<Conn, "events">, method: string, params: Record<string, unknown> | null | undefined) {
  const names = Array.isArray(params?.events) ? params!.events.map(String) : undefined;
  if (method === "events.subscribe") {
    conn.events = !names || names.includes("*") ? null : new Set(names);
  } else if (method === "events.unsubscribe") {
    if (!names) conn.events = new Set();
    else {
      const current = conn.events ?? new Set(KNOWN_EVENTS);
      for (const name of names) current.delete(name);
      conn.events = current;
    }
  } else {
    return null;
  }
  return { ok: true, events: conn.events ? [...conn.events].sort() : ["*"] };
}

export const KNOWN_EVENTS = ["windows.changed", "spaces.changed", "computer.acted", "host.healthChanged", "layers.changed", "virtual.changed"];


export interface ServeOptions {
  /** Fixed private Unix socket; remote traffic belongs to lattices-gateway. */
  socketPath: string;
  tokenFile: string;
  router: Router;
  log: (line: string) => void;
}

export function serve({ socketPath, tokenFile, router, log }: ServeOptions) {
  const token = privateToken(tokenFile);
  const sockets = new Set<ServerWebSocket<Conn>>();
  const server = Bun.serve<Conn, never>({
      unix: socketPath,
      async fetch(req, server) {
        if (req.method !== "GET" || new URL(req.url).pathname !== "/" || !authorizeLocalRequest(req, token)) return new Response("forbidden\n", { status: 403 });
        const identity: Identity = { user: "local", node: "localhost", local: true };
        if (server.upgrade(req, { data: { identity, events: null, active: new Set<AbortController>() } })) return undefined;
        // Plain HTTP GET / answers a health check, like the companion bridge.
        return Response.json({ ok: true, service: "lattices-host", transport: "private-ipc" });
      },
      websocket: {
        // Bound incoming requests; outgoing captures can be larger.
        maxPayloadLength: 1024 * 1024,
        open(ws) {
          sockets.add(ws);
          ws.data.streams = new StreamRegistry({
            send: (bytes) => ws.send(bytes),
            buffered: () => ws.getBufferedAmount(),
            event: (event, data) => { ws.send(JSON.stringify({ event, data })); },
          });
          const { user, node } = ws.data.identity;
          log(`connected ${user}@${node}`);
        },
        close(ws) {
          sockets.delete(ws);
          for (const controller of ws.data.active) controller.abort();
          ws.data.streams?.stopAll();
        },
        async message(ws, raw) {
          let request: Request;
          try {
            request = JSON.parse(String(raw));
            if (typeof request.method !== "string" || !/^[A-Za-z][A-Za-z0-9_.]{0,127}$/.test(request.method)) throw new Error("missing method");
            if (request.params != null && (typeof request.params !== "object" || Array.isArray(request.params))) throw new Error("invalid params");
            if (String(request.id ?? "?").length > 128 || ws.data.active.size >= 16) throw new Error("request limit");
            if (request.deadline !== undefined && (!Number.isFinite(request.deadline) || !Number.isSafeInteger(request.deadline))) throw new Error("invalid deadline");
          } catch {
            ws.send(JSON.stringify({ id: "?", result: null, error: "Invalid request JSON" }));
            return;
          }
          const id = String(request.id ?? "?");
          const subscription = handleSubscription(ws.data, request.method, request.params);
          if (subscription) {
            ws.send(JSON.stringify({ id, result: subscription, error: null }));
            return;
          }
          const reply = (result: unknown, error: string | null): void => {
            ws.send(JSON.stringify({ id, result: error ? null : result, error }));
          };
          const endpoint = router.lookup(request.method);
          if (STREAM_METHODS.includes(endpoint?.method ?? "")) {
            if (!router.available().includes(endpoint!)) return reply(null, `capability_unavailable: ${endpoint!.method} needs capture.stream, which this host does not have`);
            try {
              return reply(await ws.data.streams!.handle(endpoint!.method, (request.params ?? {}) as Params), null);
            } catch (err) {
              log(`${request.method} -> ${(err as Error).message}`);
              return reply(null, (err as Error).message);
            }
          }
          const controller = new AbortController();
          ws.data.active.add(controller);
          try {
            const response = await withRequestContext({ signal: controller.signal, deadline: request.deadline }, () => router.handle({ ...request, id }));
            if (response.error) log(`${request.method} -> ${response.error}`);
            if (!controller.signal.aborted) ws.send(JSON.stringify(response));
          } finally { ws.data.active.delete(controller); }
        },
      },
    });

  const removeSocket = protectSocket(socketPath);
  return {
    ports: [server.port],
    clientCount: () => sockets.size,
    broadcast(event: string, data: unknown) {
      const frame = JSON.stringify({ event, data });
      for (const ws of sockets) {
        if (!ws.data.events || ws.data.events.has(event)) ws.send(frame);
      }
    },
    stop() {
      for (const ws of sockets) for (const controller of ws.data.active) controller.abort();
      for (const ws of sockets) ws.data.streams?.stopAll();
      server.stop(true);
      removeSocket();
    },
  };
}
