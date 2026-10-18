import { withRequestContext } from "./request-context.ts";
import type { ServerWebSocket } from "bun";
import { identify, type Identity, type Policy } from "./auth.ts";
import { BridgeSecurityError } from "./bridge/security.ts";
import { gate, type ConnAuth, type DaemonPairing, type PairParams } from "./pairing.ts";
import type { Request, Router } from "./router.ts";

interface Conn {
  identity: Identity;
  auth: ConnAuth;
  /** Events this connection asked for; null means all (the default, as on the Mac). */
  events: Set<string> | null;
  active: Set<AbortController>;
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
  hosts: string[];
  port: number;
  policy: Policy;
  router: Router;
  /** Pairing for non-loopback clients; null with --no-pairing. */
  pairing: DaemonPairing | null;
  log: (line: string) => void;
}

export function serve({ hosts, port, policy, router, pairing, log }: ServeOptions) {
  const sockets = new Set<ServerWebSocket<Conn>>();

  const servers = hosts.map((hostname) =>
    Bun.serve<Conn, never>({
      hostname,
      port,
      async fetch(req, server) {
        const address = server.requestIP(req)?.address ?? "";
        const identity = await identify(address, policy);
        if (!identity) {
          log(`denied ${address}`);
          return new Response("forbidden: not an allowed tailnet identity\n", { status: 403 });
        }
        let client = null;
        if (pairing && !identity.local) {
          try {
            client = pairing.authenticate(new URL(req.url).pathname, req.headers);
          } catch (err) {
            if (!(err instanceof BridgeSecurityError)) throw err;
            log(`unauthenticated ${identity.user}@${identity.node}: ${err.message}`);
            return new Response(`${err.message}\n`, { status: err.status });
          }
        }
        const auth: ConnAuth = { local: identity.local === true, client, pairingRequired: pairing !== null };
        if (server.upgrade(req, { data: { identity, auth, events: null, active: new Set<AbortController>() } })) return undefined;
        // Plain HTTP GET / answers a health check, like the companion bridge.
        return Response.json({ ok: true, service: "lattices-host", websocket: `ws://${hostname}:${port}` });
      },
      websocket: {
        // Recordings and captures come back as base64; leave room for them.
        maxPayloadLength: 64 * 1024 * 1024,
        open(ws) {
          sockets.add(ws);
          const { user, node } = ws.data.identity;
          const client = ws.data.auth.client;
          log(`connected ${user}@${node}${client ? ` as ${client.name}` : ws.data.auth.local || !pairing ? "" : " (unpaired)"}`);
        },
        close(ws) {
          sockets.delete(ws);
          for (const controller of ws.data.active) controller.abort();
        },
        async message(ws, raw) {
          let request: Request;
          try {
            request = JSON.parse(String(raw));
            if (typeof request.method !== "string") throw new Error("missing method");
            if (request.deadline !== undefined && (!Number.isFinite(request.deadline) || !Number.isSafeInteger(request.deadline))) throw new Error("invalid deadline");
          } catch {
            ws.send(JSON.stringify({ id: "?", result: null, error: "Invalid request JSON" }));
            return;
          }
          const id = String(request.id ?? "?");
          const reply = (result: unknown, error: string | null): void => {
            ws.send(JSON.stringify({ id, result: error ? null : result, error }));
          };
          const endpoint = router.lookup(request.method);
          const denied = gate(ws.data.auth, {
            method: request.method,
            access: endpoint?.access ?? "read",
            loopbackOnly: endpoint?.loopbackOnly,
          });
          if (denied) {
            log(`${request.method} denied: ${denied.split(":")[0]}`);
            return reply(null, denied);
          }
          if (request.method === "clients.pair") {
            if (!pairing) return reply(null, "Pairing is off on this host (--no-pairing)");
            if (ws.data.auth.local) return reply(null, "Loopback is already trusted; pair from another machine");
            const result = await pairing.pair((request.params ?? {}) as PairParams, ws.data.identity);
            log(`pairing ${ws.data.identity.node}: ${result.disposition}`);
            return reply(result, null);
          }
          const subscription = handleSubscription(ws.data, request.method, request.params);
          if (subscription) {
            ws.send(JSON.stringify({ id, result: subscription, error: null }));
            return;
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
    })
  );

  return {
    ports: servers.map(server => server.port!),
    clientCount: () => sockets.size,
    /** Close the connections a revoked client has open. */
    disconnect(clientID: string) {
      for (const ws of sockets) if (ws.data.auth.client?.id === clientID) ws.close(4001, "revoked");
    },
    broadcast(event: string, data: unknown) {
      const frame = JSON.stringify({ event, data });
      for (const ws of sockets) {
        if (gate(ws.data.auth, { method: "events.subscribe", access: "read" })) continue;
        if (!ws.data.events || ws.data.events.has(event)) ws.send(frame);
      }
    },
    stop() {
      for (const ws of sockets) for (const controller of ws.data.active) controller.abort();
      for (const server of servers) server.stop(true);
    },
  };
}
