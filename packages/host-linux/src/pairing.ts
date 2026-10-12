// Pairing for the daemon socket (9399), the companion bridge's scheme applied
// to lattices clients. Tailscale whois stays the outer gate; past it, a
// non-loopback client must be paired before any method runs:
//
//   1. Unpaired, it may call only clients.pair, sending its X25519 public key.
//      A person approves on this desktop (notification) or over loopback RPC
//      (clients.approve); the requesting client can never approve itself.
//   2. Paired, it signs every WebSocket upgrade: HMAC-SHA256, keyed by HKDF
//      over the X25519 shared secret, over "GET", the path, its client id, a
//      timestamp and a nonce (headers as on the bridge). Skew and replay
//      windows are the bridge's.
//   3. Each client has a scope (LAT-014's grants). "read" runs read endpoints;
//      "act" adds the rest except driving; "drive" adds computer.* input and
//      capture.live (VNC). Drive is never granted unless asked for.
//
// Loopback is trusted, as before. --no-pairing turns step 1-3 off.

import { join } from "node:path";
import { PairingApprovals, type PendingPairing } from "./bridge/approval.ts";
import {
  BridgeSecurity,
  BridgeSecurityError,
  HEADERS,
  STATE_DIR,
  fingerprint,
  loadOrCreateBridgeKey,
  type TrustedDevice,
} from "./bridge/security.ts";
import type { Identity } from "./auth.ts";
import { RouterError, requireStr, type Json, type Router } from "./router.ts";

export type Scope = "read" | "act" | "drive";

const RANK: Record<Scope, number> = { read: 0, act: 1, drive: 2 };

/** Methods an admitted but unpaired client may call. */
export const PAIRING_METHODS = new Set(["clients.pair"]);

/** A requested scope; "mutate" (before act/drive) means act. Anything else is read. */
export function parseScope(value: unknown): Scope {
  if (value === "drive") return "drive";
  if (value === "act" || value === "mutate") return "act";
  return "read";
}

/** Scope as stored capabilities: each scope includes the ones below it. */
export function grantScope(requested: string[] | undefined): string[] {
  const top = (requested ?? []).map(parseScope).reduce<Scope>((a, b) => (RANK[b] > RANK[a] ? b : a), "read");
  return top === "drive" ? ["act", "drive", "read"] : top === "act" ? ["act", "read"] : ["read"];
}

/** Stored capabilities back to a scope. Clients paired as "mutate" are act. */
export function scopeOf(capabilities: string[]): Scope {
  if (capabilities.includes("drive")) return "drive";
  if (capabilities.includes("act") || capabilities.includes("mutate")) return "act";
  return "read";
}

/**
 * The scope a method needs. Reads need read; mutations need act, except
 * driving the desktop: computer.* input, and capture.live, whose VNC session
 * takes pointer and keyboard input. apps.open also needs drive because it
 * accepts an arbitrary command.
 */
export function scopeFor(info: Pick<MethodInfo, "method" | "access">): Scope {
  if (["capture.live", "apps.open"].includes(info.method)) return "drive";
  if (info.access === "read") return "read";
  return info.method.startsWith("computer.") ? "drive" : "act";
}

export interface ConnAuth {
  /** Loopback: trusted, may call loopback-only methods. */
  local: boolean;
  /** The paired client this connection authenticated as. */
  client: TrustedDevice | null;
  /** False with --no-pairing: admitted remote connections get full access. */
  pairingRequired: boolean;
}

export interface MethodInfo {
  method: string;
  access: "read" | "mutate";
  loopbackOnly?: boolean;
}

/** Whether a connection may call a method: null if so, else the error. Pure. */
export function gate(conn: ConnAuth, info: MethodInfo): string | null {
  if (conn.local) return null;
  if (info.loopbackOnly) return `loopback_only: ${info.method} can only be called on the host itself`;
  if (PAIRING_METHODS.has(info.method)) return null;
  if (!conn.pairingRequired) return null;
  if (!conn.client) return `pairing_required: pair this client first (lats --host <host> pair)`;
  const needs = scopeFor(info);
  const has = scopeOf(conn.client.capabilities);
  if (RANK[has] < RANK[needs]) {
    return `scope_denied: ${info.method} needs ${needs} scope; this client has ${has} (pair again with ${needs} to upgrade)`;
  }
  return null;
}

export interface PairParams {
  clientID?: string;
  clientName?: string;
  publicKey?: string;
  platform?: string;
  scope?: string;
}

export interface ClientRecord {
  id: string;
  name: string;
  node?: string;
  platform: string;
  fingerprint: string;
  scope: Scope;
  createdAt: string;
  lastSeenAt: string;
}

export function clientRecord(d: TrustedDevice): ClientRecord {
  return {
    id: d.id,
    name: d.name,
    node: d.node,
    platform: d.platform,
    fingerprint: d.fingerprint,
    scope: scopeOf(d.capabilities),
    createdAt: d.pairedAt,
    lastSeenAt: d.lastSeenAt,
  };
}

export interface DaemonPairingOptions {
  stateDir?: string;
  approvals?: PairingApprovals;
  now?: () => Date;
}

export class DaemonPairing {
  readonly approvals: PairingApprovals;
  readonly security: BridgeSecurity;

  constructor(hostName: string, options: DaemonPairingOptions = {}) {
    const dir = options.stateDir ?? STATE_DIR;
    this.approvals = options.approvals ?? new PairingApprovals(120_000, undefined, "the lattices daemon");
    this.security = new BridgeSecurity({
      bridgeName: hostName,
      privateKey: loadOrCreateBridgeKey(join(dir, "daemon-key.json")),
      devicesPath: join(dir, "daemon-clients.json"),
      approve: (request, kind, additions) => this.approvals.request(request, kind, additions),
      grant: grantScope,
      now: options.now,
    });
  }

  clients(): ClientRecord[] {
    return this.security.trustedDevices().map(clientRecord);
  }

  pending(): PendingPairing[] {
    return this.approvals.list();
  }

  revoke(id: string): boolean {
    return this.security.revoke(id);
  }

  /** Authenticate a WebSocket upgrade. Null when it carries no client id (unpaired). */
  authenticate(path: string, headers: Headers): TrustedDevice | null {
    if (!headers.get(HEADERS.deviceID)) return null;
    return this.security.authorize("GET", path, headers, Buffer.alloc(0)).device;
  }

  /** clients.pair: waits for a person to decide. `identity` comes from whois, not the client. */
  async pair(params: PairParams, identity: Identity) {
    // No scope asked: act. Drive only when asked for by name.
    const scope: Scope = params.scope === undefined ? "act" : parseScope(params.scope);
    const response = await this.security.handlePairing({
      deviceID: String(params.clientID ?? ""),
      deviceName: String(params.clientName ?? ""),
      devicePublicKey: String(params.publicKey ?? ""),
      platform: String(params.platform ?? "unknown"),
      requestedCapabilities: grantScope([scope]),
      node: identity.node,
    });
    const granted = response.grantedCapabilities;
    return {
      disposition: response.disposition,
      host: response.bridgeName,
      hostPublicKey: response.bridgePublicKey,
      hostFingerprint: response.bridgeFingerprint,
      clientFingerprint: response.disposition === "denied" ? null : fingerprint(String(params.publicKey)),
      scope: granted.length ? scopeOf(granted) : null,
      detail:
        response.disposition === "denied"
          ? response.detail
          : "Paired. Sign each connection with the derived key (x-lattices-* headers).",
    };
  }
}

export { BridgeSecurityError };


/** Daemon RPC for paired clients. Approve and deny run only over loopback. */
export function registerPairingEndpoints(router: Router, pairing: DaemonPairing, disconnect: (clientID: string) => void) {
  const asJson = (v: unknown) => v as Json;
  router.register({
    method: "clients.list",
    description: "Paired daemon clients (name, node, scope: read, act or drive, created, last seen) and pending pairings",
    access: "read",
    returns: "Object with clients, pending and the host fingerprint",
    handler: () =>
      asJson({ fingerprint: pairing.security.fingerprint, clients: pairing.clients(), pending: pairing.pending() }),
  });
  router.register({
    method: "clients.approve",
    description: "Approve a pending daemon pairing (check its fingerprint code first). Loopback only",
    access: "mutate",
    loopbackOnly: true,
    params: [{ name: "clientID", type: "string", required: true, description: "From clients.list pending" }],
    returns: "Object with ok",
    handler: (params) => {
      if (!pairing.approvals.decide(requireStr(params, "clientID"), true)) throw RouterError.notFound("pending pairing");
      return { ok: true };
    },
  });
  router.register({
    method: "clients.deny",
    description: "Deny a pending daemon pairing. Loopback only",
    access: "mutate",
    loopbackOnly: true,
    params: [{ name: "clientID", type: "string", required: true, description: "From clients.list pending" }],
    returns: "Object with ok",
    handler: (params) => {
      if (!pairing.approvals.decide(requireStr(params, "clientID"), false)) throw RouterError.notFound("pending pairing");
      return { ok: true };
    },
  });
  router.register({
    method: "clients.revoke",
    description: "Forget a paired daemon client and close its connections; it must pair again",
    access: "mutate",
    params: [{ name: "clientID", type: "string", required: true, description: "From clients.list clients" }],
    returns: "Object with ok",
    handler: (params) => {
      const id = requireStr(params, "clientID");
      if (!pairing.revoke(id)) throw RouterError.notFound("paired client");
      disconnect(id);
      return { ok: true };
    },
  });
}
