// One identity per machine (docs/security-identity.md). Every lattices role
// that needs a key uses this one X25519 key: the gateway and the companion
// bridge as servers, and gateway pairing and visit as clients. The Swift app
// reads and writes the same file (apps/mac/Sources/Core/System/DeviceIdentity.swift).
//
//   ~/.lattices/identity/device.json, 0600, in a 0700 directory:
//   {"version":1,"id":"<uuid>","name":"<host>","privateKey":{"kty":"OKP","crv":"X25519","x":"…","d":"…"}}
//
// The first run adopts a key from the per-role files that came before it,
// then removes those files. Dependency-free: Node built-ins only.

import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  randomBytes,
  randomUUID,
  type KeyObject,
} from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  linkSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir, hostname } from "node:os";
import { join } from "node:path";

export const LATTICES_DIR = join(homedir(), ".lattices");
const MAX_BYTES = 64 * 1024;

export function identityPath(base = LATTICES_DIR): string {
  return join(base, "identity", "device.json");
}

export interface DeviceIdentity {
  id: string;
  name: string;
  privateKey: KeyObject;
  /** Base64 of the raw 32-byte X25519 public key, as peers pin it. */
  publicKey: string;
  fingerprint: string;
}

interface StoredIdentity {
  version: 1;
  id: string;
  name: string;
  privateKey: { kty: "OKP"; crv: "X25519"; x: string; d: string };
}

/** The pairing code: the first 12 hex digits of SHA-256 over the base64 public key. */
export function fingerprint(publicKeyBase64: string): string {
  const hex = createHash("sha256").update(publicKeyBase64, "utf8").digest("hex");
  return hex.slice(0, 12).toUpperCase().match(/.{1,4}/g)!.join("-");
}

export function rawPublicKey(key: KeyObject): Buffer {
  const publicKey = key.type === "public" ? key : createPublicKey(key);
  return Buffer.from(publicKey.export({ format: "jwk" }).x as string, "base64url");
}

/** Per-role key files from before the device identity, in adoption order.
 * The gateway key comes first only when a client has pinned it. */
export function legacyKeyFiles(base = LATTICES_DIR) {
  return {
    gatewayKey: join(base, "gateway", "gateway-key.json"),
    gatewayClients: join(base, "gateway", "gateway-clients.json"),
    companionKey: join(base, "companion", "bridge.key"),
    hostBridgeKey: join(base, "host", "bridge-key.json"),
    client: join(base, "client.json"),
    visitKey: join(base, "visit", "device-key"),
  };
}

function privateDirectory(path: string) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid?.()) throw new Error(`Unsafe identity directory: ${path}`);
  chmodSync(path, 0o700);
}

/** An owned 0600 regular file with one link, or null when it is absent. */
function readPrivate(path: string, strict: boolean): Buffer | null {
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT" || (!strict && code === "ELOOP")) return null;
    throw error;
  }
  try {
    const stat = fstatSync(fd);
    const safe = stat.isFile() && stat.nlink === 1 && stat.uid === process.getuid?.() && stat.size <= MAX_BYTES;
    // Legacy files from older builds may be looser; the identity file never is.
    if (!safe || (strict && (stat.mode & 0o077))) {
      if (strict) throw new Error(`Unsafe device identity: ${path}`);
      return null;
    }
    return readFileSync(fd);
  } finally {
    closeSync(fd);
  }
}

function keyFromRaw(raw: Buffer): KeyObject | null {
  if (raw.length !== 32) return null;
  try {
    // PKCS#8 prefix for an X25519 private key (RFC 8410).
    const der = Buffer.concat([Buffer.from("302e020100300506032b656e04220420", "hex"), raw]);
    return createPrivateKey({ key: der, format: "der", type: "pkcs8" });
  } catch {
    return null;
  }
}

function keyFromJWK(jwk: unknown): KeyObject | null {
  const j = jwk as Record<string, unknown> | null;
  if (!j || j.kty !== "OKP" || j.crv !== "X25519" || typeof j.d !== "string") return null;
  try {
    return createPrivateKey({ key: j as never, format: "jwk" });
  } catch {
    return null;
  }
}

function parseJSON(data: Buffer | null): unknown {
  if (!data) return null;
  try { return JSON.parse(data.toString("utf8")); } catch { return null; }
}

function hasGatewayClients(path: string): boolean {
  const clients = parseJSON(readPrivate(path, false));
  return Array.isArray(clients) && clients.length > 0;
}

/** The key, id and name a first run starts from. */
export function adoptLegacy(base = LATTICES_DIR): { privateKey: KeyObject; id: string; name: string; source: string } {
  const files = legacyKeyFiles(base);
  const client = parseJSON(readPrivate(files.client, false)) as { id?: unknown; name?: unknown; privateKey?: unknown } | null;
  const gateway = () => keyFromJWK(parseJSON(readPrivate(files.gatewayKey, false)));
  const candidates: [string, () => KeyObject | null][] = [
    ["gateway", () => (hasGatewayClients(files.gatewayClients) ? gateway() : null)],
    ["companion", () => keyFromRaw(readPrivate(files.companionKey, false) ?? Buffer.alloc(0))],
    ["host-bridge", () => keyFromJWK(parseJSON(readPrivate(files.hostBridgeKey, false)))],
    ["gateway", gateway],
    ["client", () => keyFromJWK(client?.privateKey)],
    ["visit", () => keyFromRaw(readPrivate(files.visitKey, false) ?? Buffer.alloc(0))],
  ];
  const id = typeof client?.id === "string" && validID(client.id) ? client.id : randomUUID();
  const name = typeof client?.name === "string" && client.name.trim() ? client.name : hostname().replace(/\.local$/, "");
  for (const [source, load] of candidates) {
    const privateKey = load();
    if (privateKey) return { privateKey, id, name, source };
  }
  return { privateKey: generateKeyPairSync("x25519").privateKey, id, name, source: "new" };
}

function validID(id: string): boolean {
  return id.length > 0 && Buffer.byteLength(id) <= 128 && /^[\x21-\x7e]+$/.test(id);
}

function decode(data: Buffer, path: string): DeviceIdentity {
  const stored = parseJSON(data) as Partial<StoredIdentity> | null;
  const privateKey = keyFromJWK(stored?.privateKey);
  if (!stored || !privateKey || typeof stored.id !== "string" || !validID(stored.id) || typeof stored.name !== "string") {
    throw new Error(`Malformed device identity: ${path}`);
  }
  const publicRaw = rawPublicKey(privateKey);
  if (stored.privateKey!.x !== publicRaw.toString("base64url")) throw new Error(`Device identity public key mismatch: ${path}`);
  const publicKey = publicRaw.toString("base64");
  return { id: stored.id, name: stored.name, privateKey, publicKey, fingerprint: fingerprint(publicKey) };
}

/** Remove the per-role key files the identity replaced. Never follows a link. */
export function removeLegacyKeys(base = LATTICES_DIR) {
  const { gatewayClients: _clients, ...keys } = legacyKeyFiles(base);
  for (const path of Object.values(keys)) {
    try {
      const stat = lstatSync(path);
      if (stat.uid === process.getuid?.() && (stat.isFile() || stat.isSymbolicLink())) unlinkSync(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
}

/** This machine's identity, created on first use. Creation never replaces an
 * existing file: it writes a private temporary file and hard-links it in, so
 * the Swift app and the CLI racing at first launch agree on one key. */
export function deviceIdentity(base = LATTICES_DIR): DeviceIdentity {
  const path = identityPath(base);
  const existing = readPrivate(path, true);
  if (existing) return decode(existing, path);

  privateDirectory(join(base, "identity"));
  const adopted = adoptLegacy(base);
  const jwk = adopted.privateKey.export({ format: "jwk" }) as { x: string; d: string };
  const stored: StoredIdentity = { version: 1, id: adopted.id, name: adopted.name, privateKey: { kty: "OKP", crv: "X25519", x: jwk.x, d: jwk.d } };
  const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}`;
  const fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  let created = false;
  try {
    try { writeFileSync(fd, JSON.stringify(stored, null, 2) + "\n"); } finally { closeSync(fd); }
    try { linkSync(temporary, path); created = true; }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
  } finally {
    unlinkSync(temporary);
  }
  if (created) removeLegacyKeys(base);
  return decode(readPrivate(path, true)!, path);
}
