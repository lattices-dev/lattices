// The companion bridge's security, ported from
// apps/mac/Sources/Bundle/Companion/LatticesCompanionSecurityCoordinator.swift
// so the iOS app pairs with a Linux host exactly as it does with a Mac.
//
// - Keys: X25519, exchanged as base64 of the raw 32-byte public key.
// - Per-device keys: HKDF-SHA256 over the X25519 shared secret, salt
//   "lattices-bridge-v1", info "signing" or "encryption", 32 bytes.
// - Requests: HMAC-SHA256 over method, path, device id, timestamp, nonce and
//   the body's SHA-256 hex, joined with "\n"; base64 in x-lattices-signature.
// - Bodies: ChaCha20-Poly1305 "combined" (nonce || ciphertext || tag), base64,
//   with AAD naming the request or response it belongs to.

import * as chacha from "./chacha.ts";
import {
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  timingSafeEqual,
  type KeyObject,
} from "node:crypto";
import { closeSync, constants, existsSync, fstatSync, ftruncateSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { privateDirectory } from "../private-ipc.ts";

export const CAPABILITIES = {
  deckRead: "deck.read",
  deckPerform: "deck.perform",
  inputTrackpad: "input.trackpad",
  screenPreview: "screen.preview",
} as const;
/** Frozen, as in DeckKit: widening it would elevate old trust records. */
export const LEGACY_CAPABILITIES: string[] = [CAPABILITIES.deckRead, CAPABILITIES.deckPerform, CAPABILITIES.inputTrackpad];
export const DEFAULT_CAPABILITIES = [...LEGACY_CAPABILITIES, CAPABILITIES.screenPreview];

export const HEADERS = {
  deviceID: "x-lattices-device-id",
  timestamp: "x-lattices-timestamp",
  nonce: "x-lattices-nonce",
  signature: "x-lattices-signature",
} as const;

const SALT = Buffer.from("lattices-bridge-v1", "utf8");
const TIME_SKEW_SECONDS = 120;
const REPLAY_WINDOW_SECONDS = 600;

export const STATE_DIR = join(homedir(), ".lattices", "host");

export class BridgeSecurityError extends Error {
  constructor(message: string, readonly status: 401 | 403) {
    super(message);
  }
}

export interface PairingRequest {
  deviceID: string;
  deviceName: string;
  devicePublicKey: string;
  platform: string;
  appVersion?: string;
  requestedCapabilities?: string[];
  /** Tailnet node the request came from, set by the host (never by the client). */
  node?: string;
}

export interface PairingResponse {
  disposition: "approved" | "alreadyTrusted" | "denied";
  bridgeName: string;
  bridgePublicKey: string;
  bridgeFingerprint: string;
  requestSigningRequired: true;
  payloadEncryptionRequired: true;
  grantedCapabilities: string[];
  detail?: string;
}

export interface TrustedDevice {
  id: string;
  name: string;
  publicKey: string;
  fingerprint: string;
  platform: string;
  appVersion?: string;
  capabilities: string[];
  node?: string;
  pairedAt: string;
  lastSeenAt: string;
}

export interface AuthorizedRequest {
  device: TrustedDevice;
  nonce: string;
  timestamp: string;
}

// ── Primitives ────────────────────────────────────────────────────────

const b64url = (b: Buffer) => b.toString("base64url");
const fromB64url = (s: string) => Buffer.from(s, "base64url");

export function fingerprint(publicKeyBase64: string): string {
  const hex = createHash("sha256").update(publicKeyBase64, "utf8").digest("hex");
  return hex.slice(0, 12).toUpperCase().match(/.{1,4}/g)!.join("-");
}

export function publicKeyFromBase64(value: string): KeyObject | null {
  const raw = Buffer.from(value, "base64");
  if (raw.length !== 32 || raw.toString("base64") !== value.replace(/\s/g, "")) return null;
  try {
    return createPublicKey({ key: { kty: "OKP", crv: "X25519", x: b64url(raw) }, format: "jwk" });
  } catch {
    return null;
  }
}

export function rawPublicKey(key: KeyObject): Buffer {
  return fromB64url(key.export({ format: "jwk" }).x as string);
}

export function deriveKeys(privateKey: KeyObject, peerPublicKey: KeyObject): { signing: Buffer; encryption: Buffer } {
  const secret = diffieHellman({ privateKey, publicKey: peerPublicKey });
  const derive = (info: string) => Buffer.from(hkdfSync("sha256", secret, SALT, Buffer.from(info, "utf8"), 32));
  return { signing: derive("signing"), encryption: derive("encryption") };
}

export function canonicalRequest(method: string, path: string, deviceID: string, timestamp: string, nonce: string, body: Buffer): Buffer {
  const bodyHash = createHash("sha256").update(body).digest("hex");
  return Buffer.from([method.toUpperCase(), path, deviceID, timestamp, nonce, bodyHash].join("\n"), "utf8");
}

export function sign(signingKey: Buffer, canonical: Buffer): string {
  return createHmac("sha256", signingKey).update(canonical).digest("base64");
}

export function requestAAD(method: string, path: string, deviceID: string, timestamp: string, nonce: string): Buffer {
  return Buffer.from(["request", method.toUpperCase(), path, deviceID, timestamp, nonce].join("\n"), "utf8");
}

export function responseAAD(status: number, path: string, deviceID: string, nonce: string): Buffer {
  return Buffer.from(["response", String(status), path, deviceID, nonce].join("\n"), "utf8");
}

/** ChaChaPoly.seal(...).combined, base64: nonce (12) || ciphertext || tag (16). */
export function seal(key: Buffer, plaintext: Buffer, aad: Buffer): string {
  const nonce = randomBytes(12);
  const { ciphertext, tag } = chacha.seal(key, nonce, plaintext, aad);
  return Buffer.concat([nonce, ciphertext, tag]).toString("base64");
}

export function open(key: Buffer, sealedBase64: string, aad: Buffer): Buffer {
  const combined = Buffer.from(sealedBase64, "base64");
  if (combined.length < 28) throw new BridgeSecurityError("The request body is not a valid encrypted envelope.", 401);
  const plaintext = chacha.open(
    key,
    combined.subarray(0, 12),
    combined.subarray(12, combined.length - 16),
    combined.subarray(combined.length - 16),
    aad
  );
  if (!plaintext) throw new BridgeSecurityError("The request body is not a valid encrypted envelope.", 401);
  return Buffer.from(plaintext);
}

export type VisitDirection = "up" | "down";

export function visitAAD(direction: VisitDirection, deviceID: string, upgradeNonce: string, seq: number): Buffer {
  if (!Number.isSafeInteger(seq) || seq < 0) throw new Error("Invalid visit sequence");
  return Buffer.from(["visit", direction, deviceID, upgradeNonce, String(seq)].join("\n"), "utf8");
}

/** Raw ChaChaPoly combined box; visit frames are binary, never base64. */
export function sealVisitFrame(key: Buffer, plaintext: Buffer, direction: VisitDirection, deviceID: string, upgradeNonce: string, seq: number): Buffer {
  const nonce = randomBytes(12);
  const { ciphertext, tag } = chacha.seal(key, nonce, plaintext, visitAAD(direction, deviceID, upgradeNonce, seq));
  return Buffer.concat([nonce, ciphertext, tag]);
}

export function openVisitFrame(key: Buffer, combined: Buffer, direction: VisitDirection, deviceID: string, upgradeNonce: string, seq: number): Buffer {
  if (combined.length < 28) throw new BridgeSecurityError("Invalid visit frame", 401);
  const plaintext = chacha.open(key, combined.subarray(0, 12), combined.subarray(12, -16), combined.subarray(-16),
    visitAAD(direction, deviceID, upgradeNonce, seq));
  if (!plaintext) throw new BridgeSecurityError("Invalid visit frame", 401);
  return Buffer.from(plaintext);
}

function constantTimeEquals(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export function grantedCapabilities(requested: string[] | undefined): string[] {
  const supported = new Set<string>(DEFAULT_CAPABILITIES);
  const asked = requested === undefined ? LEGACY_CAPABILITIES : requested.length === 0 ? [...supported] : requested;
  return [...new Set(asked)].filter((c) => supported.has(c)).sort();
}

// ── Persistent state ──────────────────────────────────────────────────

function writePrivate(path: string, data: string) {
  privateDirectory(dirname(path));
  const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
  try {
    validatePrivateFile(fd, path);
    ftruncateSync(fd, 0);
    writeFileSync(fd, data);
  } finally { closeSync(fd); }
}

function validatePrivateFile(fd: number, path: string) {
  const stat = fstatSync(fd);
  if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid?.() || (stat.mode & 0o077)) throw new Error(`Unsafe pairing state: ${path}`);
}

function readPrivate(path: string): string {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try { validatePrivateFile(fd, path); return readFileSync(fd, "utf8"); }
  finally { closeSync(fd); }
}

export function loadOrCreateBridgeKey(path = join(STATE_DIR, "bridge-key.json")): KeyObject {
  if (existsSync(path)) {
    const jwk = JSON.parse(readPrivate(path));
    return createPrivateKey({ key: jwk, format: "jwk" });
  }
  const { privateKey } = generateKeyPairSync("x25519");
  writePrivate(path, JSON.stringify(privateKey.export({ format: "jwk" })));
  return privateKey;
}

// ── The coordinator ───────────────────────────────────────────────────

export interface CoordinatorOptions {
  bridgeName: string;
  privateKey?: KeyObject;
  devicesPath?: string;
  /** Asks a person; resolves true to trust the device. */
  approve: (request: PairingRequest, kind: "pair" | "upgrade", additions: string[]) => Promise<boolean>;
  /** What a request is granted; the companion capabilities by default. */
  grant?: (requested: string[] | undefined) => string[];
  now?: () => Date;
}

export class BridgeSecurity {
  readonly privateKey: KeyObject;
  readonly publicKeyBase64: string;
  readonly fingerprint: string;
  private devices = new Map<string, TrustedDevice>();
  private seen = new Map<string, number>();
  private readonly devicesPath: string;
  private readonly now: () => Date;

  constructor(private options: CoordinatorOptions) {
    this.privateKey = options.privateKey ?? loadOrCreateBridgeKey();
    this.publicKeyBase64 = rawPublicKey(createPublicKey(this.privateKey)).toString("base64");
    this.fingerprint = fingerprint(this.publicKeyBase64);
    this.devicesPath = options.devicesPath ?? join(STATE_DIR, "bridge-devices.json");
    this.now = options.now ?? (() => new Date());
    if (existsSync(this.devicesPath)) {
      for (const d of JSON.parse(readPrivate(this.devicesPath)) as TrustedDevice[]) this.devices.set(d.id, d);
    }
  }

  trustedDevices(): TrustedDevice[] {
    return [...this.devices.values()].sort((a, b) => a.name.localeCompare(b.name));
  }

  revoke(id: string): boolean {
    const removed = this.devices.delete(id);
    if (removed) this.persist();
    return removed;
  }

  private persist() {
    writePrivate(this.devicesPath, JSON.stringify(this.trustedDevices(), null, 2));
  }

  private response(disposition: PairingResponse["disposition"], granted: string[], detail: string): PairingResponse {
    return {
      disposition,
      bridgeName: this.options.bridgeName,
      bridgePublicKey: this.publicKeyBase64,
      bridgeFingerprint: this.fingerprint,
      requestSigningRequired: true,
      payloadEncryptionRequired: true,
      grantedCapabilities: granted,
      detail,
    };
  }

  async handlePairing(request: PairingRequest): Promise<PairingResponse> {
    const granted = (this.options.grant ?? grantedCapabilities)(request.requestedCapabilities);
    if (!request.deviceID?.trim() || !request.deviceName?.trim() || !publicKeyFromBase64(request.devicePublicKey ?? "")) {
      return this.response("denied", [], "The paired device key is invalid.");
    }
    const existing = this.devices.get(request.deviceID);
    if (existing && existing.publicKey === request.devicePublicKey) {
      const additions = granted.filter((c) => !existing.capabilities.includes(c)).sort();
      const approved = additions.length === 0 || (await this.options.approve(request, "upgrade", additions));
      existing.capabilities = approved ? [...new Set([...existing.capabilities, ...granted])].sort() : existing.capabilities;
      existing.lastSeenAt = this.now().toISOString();
      this.persist();
      return this.response("alreadyTrusted", existing.capabilities, "This device is already trusted on this host.");
    }
    if (!(await this.options.approve(request, "pair", granted))) {
      return this.response("denied", [], "Pairing was denied on the host.");
    }
    const at = this.now().toISOString();
    this.devices.set(request.deviceID, {
      id: request.deviceID,
      name: request.deviceName,
      publicKey: request.devicePublicKey,
      fingerprint: fingerprint(request.devicePublicKey),
      platform: request.platform,
      appVersion: request.appVersion,
      capabilities: granted,
      node: request.node,
      pairedAt: at,
      lastSeenAt: at,
    });
    this.persist();
    return this.response("approved", granted, "Trusted and ready for encrypted bridge requests.");
  }

  private keysFor(device: TrustedDevice) {
    const peer = publicKeyFromBase64(device.publicKey);
    if (!peer) throw new BridgeSecurityError("The paired device key is invalid.", 401);
    return deriveKeys(this.privateKey, peer);
  }

  authorize(method: string, path: string, headers: Headers, body: Buffer): AuthorizedRequest {
    const header = (name: string) => {
      const value = headers.get(name);
      if (!value) throw new BridgeSecurityError(`Missing required header ${name}.`, 401);
      return value;
    };
    const deviceID = header(HEADERS.deviceID);
    const timestamp = header(HEADERS.timestamp);
    const nonce = header(HEADERS.nonce);
    const signature = header(HEADERS.signature);

    const device = this.devices.get(deviceID);
    if (!device) throw new BridgeSecurityError("This device is not trusted on the host. Pair it again.", 403);

    const at = Date.parse(timestamp);
    const now = this.now().getTime();
    if (!Number.isFinite(at) || Math.abs(at - now) > TIME_SKEW_SECONDS * 1000) {
      throw new BridgeSecurityError("The request timestamp is outside the allowed window.", 401);
    }
    for (const [key, seenAt] of this.seen) if (now - seenAt >= REPLAY_WINDOW_SECONDS * 1000) this.seen.delete(key);
    const replayKey = `${deviceID}:${nonce}`;
    if (this.seen.has(replayKey)) throw new BridgeSecurityError("The request nonce was already used.", 401);

    const expected = sign(this.keysFor(device).signing, canonicalRequest(method, path, deviceID, timestamp, nonce, body));
    if (!constantTimeEquals(signature, expected)) throw new BridgeSecurityError("The request signature is invalid.", 401);

    this.seen.set(replayKey, now);
    if (now - Date.parse(device.lastSeenAt) >= 30_000) {
      device.lastSeenAt = this.now().toISOString();
      this.persist();
    }
    return { device, nonce, timestamp };
  }

  requireCapability(capability: string, auth: AuthorizedRequest) {
    if (!auth.device.capabilities.includes(capability)) {
      throw new BridgeSecurityError(`This device is not allowed to use ${capability}. Pair it again to grant it.`, 403);
    }
  }

  visitEncryptionKey(auth: AuthorizedRequest): Buffer {
    this.requireCapability(CAPABILITIES.inputTrackpad, auth);
    return this.keysFor(auth.device).encryption;
  }

  decodeBody<T>(body: Buffer, auth: AuthorizedRequest, method: string, path: string): T {
    let envelope: { sealedBox?: string };
    try {
      envelope = JSON.parse(body.toString("utf8"));
    } catch {
      throw new BridgeSecurityError("The request body is not a valid encrypted envelope.", 401);
    }
    if (typeof envelope.sealedBox !== "string") throw new BridgeSecurityError("The request body is not a valid encrypted envelope.", 401);
    const plaintext = open(this.keysFor(auth.device).encryption, envelope.sealedBox, requestAAD(method, path, auth.device.id, auth.timestamp, auth.nonce));
    return JSON.parse(plaintext.toString("utf8")) as T;
  }

  encodeResponse(value: unknown, auth: AuthorizedRequest, status: number, path: string): { sealedBox: string } {
    const plaintext = Buffer.from(JSON.stringify(value), "utf8");
    return { sealedBox: seal(this.keysFor(auth.device).encryption, plaintext, responseAAD(status, path, auth.device.id, auth.nonce)) };
  }
}
