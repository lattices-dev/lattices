// Client side of lattices-host pairing (LAT-013). A remote host admits this
// machine only after a person approves it once; after that every daemon
// connection is signed. Mirrors packages/host-linux/src/pairing.ts and the
// companion scheme in packages/host-linux/src/bridge/security.ts:
//
//   - This client has one X25519 key and id, in ~/.lattices/client.json.
//   - Paired hosts (their public key, fingerprint, granted scope) are kept in
//     ~/.lattices/paired-hosts.json, keyed by address:port.
//   - Each WebSocket upgrade carries x-lattices-device-id, -timestamp, -nonce
//     and -signature: base64 HMAC-SHA256, keyed by HKDF-SHA256 over the X25519
//     shared secret (salt "lattices-bridge-v1", info "signing"), over
//     "GET\n<path>\n<id>\n<timestamp>\n<nonce>\n<sha256 of empty body>".

import {
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  randomUUID,
  type KeyObject,
} from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, hostname, platform } from "node:os";
import { dirname, join } from "node:path";

const STATE_DIR = join(homedir(), ".lattices");
export const CLIENT_FILE = join(STATE_DIR, "client.json");
export const PAIRED_HOSTS_FILE = join(STATE_DIR, "paired-hosts.json");

const SALT = Buffer.from("lattices-bridge-v1", "utf8");

export interface PairedHost {
  host: string;
  hostPublicKey: string;
  hostFingerprint: string;
  /** "mutate" in files written before the act/drive split; read it as act. */
  scope: "read" | "act" | "drive" | "mutate";
  pairedAt: string;
}

interface ClientIdentity {
  id: string;
  name: string;
  privateKey: KeyObject;
  publicKey: string;
}

function writePrivate(path: string, data: string) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, data, { mode: 0o600 });
  chmodSync(path, 0o600);
}

function rawPublicKey(key: KeyObject): string {
  return Buffer.from(key.export({ format: "jwk" }).x as string, "base64url").toString("base64");
}

export function fingerprint(publicKeyBase64: string): string {
  const hex = createHash("sha256").update(publicKeyBase64, "utf8").digest("hex");
  return hex.slice(0, 12).toUpperCase().match(/.{1,4}/g)!.join("-");
}

export function clientIdentity(path = CLIENT_FILE): ClientIdentity {
  let stored: { id: string; name: string; privateKey: Record<string, unknown> };
  if (existsSync(path)) {
    stored = JSON.parse(readFileSync(path, "utf8"));
  } else {
    const { privateKey } = generateKeyPairSync("x25519");
    stored = { id: randomUUID(), name: hostname().replace(/\.local$/, ""), privateKey: privateKey.export({ format: "jwk" }) as Record<string, unknown> };
    writePrivate(path, JSON.stringify(stored, null, 2));
  }
  const privateKey = createPrivateKey({ key: stored.privateKey as never, format: "jwk" });
  return { id: stored.id, name: stored.name, privateKey, publicKey: rawPublicKey(createPublicKey(privateKey)) };
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
  const client = clientIdentity();
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
export function pairingRequest(scope: "read" | "act" | "drive") {
  const client = clientIdentity();
  return {
    params: { clientID: client.id, clientName: client.name, publicKey: client.publicKey, platform: platform(), scope },
    fingerprint: fingerprint(client.publicKey),
  };
}
