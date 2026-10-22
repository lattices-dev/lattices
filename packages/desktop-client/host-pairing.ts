// Client side of lattices-host pairing (LAT-013). A remote host admits this
// machine only after a person approves it once; after that every daemon
// connection is signed. Mirrors packages/host-linux/src/pairing.ts and the
// companion scheme in packages/host-linux/src/bridge/security.ts:
//
//   - This client signs with the machine's device identity: one X25519 key
//     and id in ~/.lattices/identity/device.json (device-identity.ts).
//   - Paired hosts (their public key, fingerprint, granted scope) are kept in
//     ~/.lattices/paired-hosts.json, keyed by address:port.
//   - Each WebSocket upgrade carries x-lattices-device-id, -timestamp, -nonce
//     and -signature: base64 HMAC-SHA256, keyed by HKDF-SHA256 over the X25519
//     shared secret (salt "lattices-bridge-v1", info "signing"), over
//     "GET\n<path>\n<id>\n<timestamp>\n<nonce>\n<sha256 of empty body>".

import { createHash, createHmac, createPublicKey, diffieHellman, hkdfSync, randomBytes, type KeyObject } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { platform } from "node:os";
import { dirname, join } from "node:path";
import { LATTICES_DIR, deviceIdentity, fingerprint, identityPath } from "./device-identity.ts";

export { fingerprint };
export const IDENTITY_FILE = identityPath();
export const PAIRED_HOSTS_FILE = join(LATTICES_DIR, "paired-hosts.json");

const SALT = Buffer.from("lattices-bridge-v1", "utf8");

export interface PairedHost {
  host: string;
  hostPublicKey: string;
  hostFingerprint: string;
  /** "mutate" in files written before the act/drive split; read it as act. */
  scope: "read" | "act" | "drive" | "mutate";
  /** Core scopes the gateway granted. Absent in files written before screen
   * and shell were split out; pairedScopes reads those by the old meaning. */
  scopes?: string[];
  pairedAt: string;
}

export const PAIRING_SCOPES = ["read", "screen", "act", "drive", "shell"] as const;
export type PairingScope = typeof PAIRING_SCOPES[number];

/** The core scopes a pairing holds. Before the split, read also saw the
 * screen and drive also ran commands, so older entries keep that meaning. */
export function pairedScopes(entry: PairedHost): PairingScope[] {
  if (Array.isArray(entry.scopes)) return PAIRING_SCOPES.filter((s) => entry.scopes!.includes(s));
  if (entry.scope === "drive") return [...PAIRING_SCOPES];
  if (entry.scope === "act" || entry.scope === "mutate") return ["read", "screen", "act"];
  return ["read", "screen"];
}

/** One word for a pairing: its shorthand, plus any extra scope. */
export function pairingLabel(entry: PairedHost): string {
  const held = pairedScopes(entry);
  const base = held.includes("drive") ? "drive" : held.includes("act") ? "act" : held.includes("read") ? "read" : "grants";
  const implied: Record<string, PairingScope[]> = { drive: ["read", "screen", "act", "drive", "shell"], act: ["read", "screen", "act"], read: ["read"], grants: [] };
  const extra = held.filter((s) => !implied[base]!.includes(s));
  const missing = implied[base]!.filter((s) => !held.includes(s));
  return [base, ...extra.map((s) => `+${s}`), ...missing.map((s) => `-${s}`)].join("");
}

function writePrivate(path: string, data: string) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, data, { mode: 0o600 });
  chmodSync(path, 0o600);
}

function readPairedHosts(path = PAIRED_HOSTS_FILE): Record<string, PairedHost> {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return {};
  }
}

/** The pairing for an endpoint: by address:port, else by the host's tailnet name. */
export function pairedHost(
  endpoint: { host: string; port: number },
  hosts: Record<string, PairedHost> = readPairedHosts()
): PairedHost | null {
  const exact = hosts[`${endpoint.host}:${endpoint.port}`];
  if (exact) return exact;
  const short = endpoint.host.split(".")[0]!.toLowerCase();
  const byName = Object.entries(hosts).find(
    ([key, h]) => h.host.toLowerCase() === short && key.endsWith(`:${endpoint.port}`)
  );
  return byName?.[1] ?? null;
}

export function savePairedHost(endpoint: { host: string; port: number }, entry: PairedHost, path = PAIRED_HOSTS_FILE) {
  const hosts = readPairedHosts(path);
  hosts[`${endpoint.host}:${endpoint.port}`] = entry;
  writePrivate(path, JSON.stringify(hosts, null, 2));
}

export function signingKey(privateKey: KeyObject, hostPublicKeyBase64: string): Buffer {
  const peer = createPublicKey({
    key: { kty: "OKP", crv: "X25519", x: Buffer.from(hostPublicKeyBase64, "base64").toString("base64url") },
    format: "jwk",
  });
  const secret = diffieHellman({ privateKey, publicKey: peer });
  return Buffer.from(hkdfSync("sha256", secret, SALT, Buffer.from("signing", "utf8"), 32));
}

export function signUpgrade(key: Buffer, path: string, clientID: string, timestamp: string, nonce: string): string {
  const emptyBody = createHash("sha256").update(Buffer.alloc(0)).digest("hex");
  const canonical = ["GET", path, clientID, timestamp, nonce, emptyBody].join("\n");
  return createHmac("sha256", key).update(canonical, "utf8").digest("base64");
}

/** Upgrade headers for a paired endpoint; none when it is not paired. */
export function pairingHeaders(endpoint: { host: string; port: number }, path = "/"): string[] {
  const paired = pairedHost(endpoint);
  if (!paired) return [];
  const client = deviceIdentity();
  const timestamp = new Date().toISOString();
  const nonce = randomBytes(16).toString("hex");
  const signature = signUpgrade(signingKey(client.privateKey, paired.hostPublicKey), path, client.id, timestamp, nonce);
  return [
    `x-lattices-device-id: ${client.id}`,
    `x-lattices-timestamp: ${timestamp}`,
    `x-lattices-nonce: ${nonce}`,
    `x-lattices-signature: ${signature}`,
  ];
}

/** clients.pair parameters for this machine. */
export function pairingRequest(scope: "read" | "act" | "drive", scopes: PairingScope[] = []) {
  const client = deviceIdentity();
  return {
    params: { clientID: client.id, clientName: client.name, publicKey: client.publicKey, platform: platform(), scope, ...(scopes.length ? { scopes } : {}) },
    fingerprint: fingerprint(client.publicKey),
  };
}
