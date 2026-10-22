// The companion bridge over HTTP, matching
// apps/mac/Sources/Bundle/Companion/LatticesCompanionBridgeServer.swift:
// The runtime uses a private Unix socket. The optional remote gateway serves
// these same signed routes on its own port (9399 by default).

import { authorizeLocalRequest, protectSocket, type LocalCredential } from "../private-ipc.ts";
import { spawn, type ChildProcess } from "node:child_process";
import { hostname } from "node:os";
import { hasCommand } from "../exec.ts";
import { PairingApprovals } from "./approval.ts";
import * as deck from "./deck.ts";
import { join } from "node:path";
import { BridgeSecurity, BridgeSecurityError, CAPABILITIES, DEFAULT_CAPABILITIES, loadOrCreateBridgeKey, type AuthorizedRequest, type PairingRequest } from "./security.ts";
import { VisitChannel, Visits } from "./visit-channel.ts";
import { ENDED_HERE, startVisitControl } from "./visit-control.ts";
import { QuickshellVisitorOverlay } from "./visitor-overlay.ts";
import type { VisitDependencies, VisitorOverlay } from "./visit.ts";

export const BRIDGE_PORT = 9399;
const MAX_BODY_BYTES = 512 * 1024;

export interface BridgeOptions {
  hosts: string[];
  socketPath?: string;
  token?: LocalCredential;
  port?: number;
  name?: string;
  version: string;
  trackpadAvailable: () => boolean;
  hasTmux: () => boolean;
  log: (line: string) => void;
  security?: BridgeSecurity;
  approvals?: PairingApprovals;
  /** Isolate a second host's keys and trust records from the everyday host. */
  stateDir?: string;
  visitOverlay?: VisitorOverlay;
  visitDependencies?: VisitDependencies;
  /** Where to listen for this machine's own "end every visit". Off when unset. */
  controlDir?: string;
  /** Only tests shorten the six-second production timeout. */
  visitSilenceMs?: number;
  /** Tests inject a snapshot instead of reading Hyprland. */
  snapshot?: () => Promise<unknown>;
}

const json = (status: number, value: unknown) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json; charset=utf-8", connection: "close" } });

const error = (status: number, message: string) => json(status, { ok: false, error: message });

/** 0.0.0.0 or a private LAN address; not loopback and not the tailnet's 100.64.0.0/10. */
export function isLanAddress(address: string): boolean {
  if (address === "0.0.0.0") return true;
  const parts = address.split(".").map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n))) return false;
  const [a, b] = parts;
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}

export function startBridge(options: BridgeOptions) {
  let stopping = false;
  const name = options.name ?? hostname();
  const approvals = options.approvals ?? new PairingApprovals();
  const security =
    options.security ??
    new BridgeSecurity({
      bridgeName: name,
      ...(options.stateDir ? { privateKey: loadOrCreateBridgeKey(join(options.stateDir, "bridge-key.json")), devicesPath: join(options.stateDir, "bridge-devices.json") } : {}),
      approve: (request, kind, additions) => {
        options.log(`pairing ${kind} from ${request.deviceName} (${request.deviceID}); approve in the notification or with bridge.pairing.approve`);
        return approvals.request(request, kind, additions);
      },
    });
  const trackpad = new deck.Trackpad();
  const visits = new Visits(options.visitOverlay ?? new QuickshellVisitorOverlay(options.log), options.visitDependencies);
  const snapshot = options.snapshot ?? (() => deck.runtimeSnapshot(options.trackpadAvailable(), options.hasTmux()));

  async function route(req: Request): Promise<Response> {
    const path = new URL(req.url).pathname;
    const method = req.method.toUpperCase();
    const body = Buffer.from(await req.arrayBuffer());
    if (body.length > MAX_BODY_BYTES) return error(413, "Request body is too large");

    const protectedCall = async <T>(capability: string, handler: (input: T | undefined) => Promise<unknown>, hasBody: boolean) => {
      const auth = security.authorize(method, path, req.headers, body);
      security.requireCapability(capability, auth);
      const input = hasBody ? security.decodeBody<T>(body, auth, method, path) : undefined;
      const result = await handler(input);
      return json(200, security.encodeResponse(result, auth, 200, path));
    };

    switch (`${method} ${path}`) {
      case "GET /health":
        return json(200, {
          ok: true,
          name,
          serviceType: "_lattices-companion._tcp.",
          hostName: hostname(),
          port: boundPort(),
          protocolVersion: "1",
          version: options.version,
          mode: "private-ipc-gateway",
          bridgePublicKey: security.publicKeyBase64,
          bridgeFingerprint: security.fingerprint,
          requestSigningRequired: true,
          payloadEncryptionRequired: true,
          capabilities: DEFAULT_CAPABILITIES,
        });
      case "GET /deck/manifest":
        return json(200, deck.manifest(name));
      case "POST /pairing/request": {
        const request = JSON.parse(body.toString("utf8")) as PairingRequest;
        const priorKey = security.trustedDevices().find(device => device.id === request.deviceID)?.publicKey;
        const response = await security.handlePairing(request);
        if (response.disposition === "approved" && priorKey && priorKey !== request.devicePublicKey) {
          await Promise.all([...visits.channels].filter(channel => channel.deviceID === request.deviceID).map(channel => channel.finish(4001, "Device key changed")));
        }
        options.log(`pairing ${response.disposition} for ${request.deviceName}`);
        return json(response.disposition === "denied" ? 403 : 200, response);
      }
      case "GET /deck/snapshot":
        return protectedCall(CAPABILITIES.deckRead, () => snapshot(), false);
      case "POST /deck/perform":
        return protectedCall<deck.DeckActionRequest>(CAPABILITIES.deckPerform, (input) => deck.perform(input!, snapshot), true);
      case "POST /deck/trackpad":
        return protectedCall<deck.TrackpadEvent>(CAPABILITIES.inputTrackpad, (input) => trackpad.perform(input!), true);
      case "POST /deck/preview":
        return protectedCall<deck.PreviewRequest>(CAPABILITIES.screenPreview, (input) => deck.preview(input ?? {}), true);
      default:
        return error(404, "Unknown route");
    }
  }

  const boundPort = () => servers[0]?.port ?? options.port ?? BRIDGE_PORT;
  type VisitSocketData = { auth: AuthorizedRequest; channel?: VisitChannel };
  if (!options.socketPath && options.hosts.some(host => host !== "127.0.0.1")) throw new Error("Companion remote access belongs to lattices-gateway");
  const listeners = options.socketPath ? [{ unix: options.socketPath }] : options.hosts.map(hostname => ({ hostname, port: options.port ?? BRIDGE_PORT }));
  if (options.socketPath && !options.token) throw new Error("Private companion token required");
  const servers = listeners.map((listener) =>
    Bun.serve<VisitSocketData>({
      ...listener,
      maxRequestBodySize: MAX_BODY_BYTES,
      async fetch(req, server) {
        try {
          if (req.headers.has("origin")) return error(403, "Browser origins are not allowed");
          if (options.socketPath && !authorizeLocalRequest(req, options.token!)) return error(403, "Local authentication required");
          if (stopping) return error(503, "Bridge stopping");
          if (req.method === "GET" && new URL(req.url).pathname === "/visit") {
            const body = Buffer.from(await req.arrayBuffer());
            if (body.length) return error(400, "Visit upgrade body must be empty");
            const auth = security.authorize("GET", "/visit", req.headers, body);
            security.requireCapability(CAPABILITIES.inputTrackpad, auth);
            if (server.upgrade(req, { data: { auth } })) return;
            return error(400, "WebSocket upgrade required");
          }
          return await route(req);
        } catch (err) {
          if (err instanceof BridgeSecurityError) return error(err.status, err.message);
          if (err instanceof SyntaxError) return error(400, "Invalid JSON body");
          return error(500, (err as Error).message);
        }
      },
      websocket: {
        maxPayloadLength: MAX_BODY_BYTES,
        idleTimeout: 0, // the encrypted visit protocol owns its six-second timer
        open(ws) {
          ws.data.channel = new VisitChannel(ws, ws.data.auth, security, visits, options.visitSilenceMs);
          if (stopping) void ws.data.channel.finish(1001, "Host stopping");
        },
        message(ws, message) { ws.data.channel?.receive(message); },
        close(ws) { void ws.data.channel?.finish(); },
      },
    })
  );

  const removeSocket = options.socketPath ? protectSocket(options.socketPath) : () => {};
  const endVisits = async () => {
    const channels = [...visits.channels];
    await Promise.all(channels.map((channel) => channel.finish(1000, ENDED_HERE)));
    if (channels.length) options.log(`ended ${channels.length} visit channel(s) from this machine`);
    return channels.length;
  };
  const control = options.controlDir ? startVisitControl(options.controlDir, boundPort(), endVisits) : null;

  // Bonjour, as the Mac publishes it, so a phone on the same LAN finds this
  // host. Only when the bridge listens on a LAN address: the tailnet and
  // loopback are not reachable from what Bonjour would resolve.
  let advert: ChildProcess | null = null;
  if (options.hosts.some(isLanAddress) && hasCommand("avahi-publish-service")) {
    advert = spawn("avahi-publish-service", [name, "_lattices-companion._tcp", String(boundPort())], { stdio: "ignore" });
    advert.on("error", () => {});
    options.log(`advertising _lattices-companion._tcp on the LAN as ${name}`);
  }

  return {
    security,
    approvals,
    port: boundPort(),
    advertised: advert !== null,
    controlPath: control?.path ?? null,
    endVisits,
    async revoke(deviceID: string) {
      approvals.decide(deviceID, false);
      if (!security.revoke(deviceID)) return false;
      await Promise.all([...visits.channels]
        .filter((channel) => channel.deviceID === deviceID)
        .map((channel) => channel.finish(4001, "Device revoked")));
      return true;
    },
    async stop() {
      stopping = true;
      advert?.kill();
      control?.stop();
      await visits.stop();
      for (const s of servers) s.stop(true);
      removeSocket();
    },
  };
}

import { RouterError, requireStr, type Json, type Router } from "../router.ts";

/** Daemon RPC for the bridge: see and decide pairings, manage trusted devices. */
export function registerBridgeEndpoints(router: Router, bridge: ReturnType<typeof startBridge>, port: number, hosts: string[]) {
  const asJson = (v: unknown) => v as Json;
  router.register({
    method: "bridge.status",
    description: "The iOS companion bridge: where it listens, its fingerprint, pending pairings and trusted devices",
    access: "read",
    returns: "Object with addresses, fingerprint, pending and devices",
    handler: () =>
      asJson({
        addresses: hosts.map((h) => `${h}:${port}`),
        fingerprint: bridge.security.fingerprint,
        pending: bridge.approvals.list(),
        devices: bridge.security.trustedDevices().map(({ publicKey: _key, ...rest }) => rest),
      }),
  });
  router.register({
    method: "bridge.pairing.approve",
    description: "Approve a pending companion pairing (check its fingerprint code first). Loopback only",
    access: "mutate",
    loopbackOnly: true,
    params: [{ name: "deviceID", type: "string", required: true, description: "From bridge.status pending" }],
    returns: "Object with ok",
    handler: (params) => {
      if (!bridge.approvals.decide(requireStr(params, "deviceID"), true)) throw RouterError.notFound("pending pairing");
      return { ok: true };
    },
  });
  router.register({
    method: "bridge.pairing.deny",
    description: "Deny a pending companion pairing. Loopback only",
    access: "mutate",
    loopbackOnly: true,
    params: [{ name: "deviceID", type: "string", required: true, description: "From bridge.status pending" }],
    returns: "Object with ok",
    handler: (params) => {
      if (!bridge.approvals.decide(requireStr(params, "deviceID"), false)) throw RouterError.notFound("pending pairing");
      return { ok: true };
    },
  });
  router.register({
    method: "bridge.devices.revoke",
    description: "Forget a trusted companion device and close its visits; it must pair again",
    access: "mutate",
    params: [{ name: "deviceID", type: "string", required: true, description: "From bridge.status devices" }],
    returns: "Object with ok",
    handler: async (params) => {
      if (!await bridge.revoke(requireStr(params, "deviceID"))) throw RouterError.notFound("trusted device");
      return { ok: true };
    },
  });
}
