// The companion bridge against a client written the way the iOS app's
// DeckBridgeSecurityStore.swift is: its own X25519 key, HKDF, HMAC signature
// and ChaChaPoly envelopes, implemented here independently of the server.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash, createHmac, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes, randomUUID } from "node:crypto";
// Bun's node:crypto has no chacha20-poly1305; the AEAD itself is checked
// against RFC 8439 and OpenSSL in the chacha tests.
import * as aead from "../src/bridge/chacha.ts";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PairingApprovals } from "../src/bridge/approval.ts";
import { BridgeSecurity, fingerprint } from "../src/bridge/security.ts";
import { startBridge } from "../src/bridge/server.ts";

class PhoneClient {
  readonly deviceID = randomUUID().toLowerCase();
  private key = generateKeyPairSync("x25519");
  readonly publicKey = Buffer.from(this.key.publicKey.export({ format: "jwk" }).x as string, "base64url").toString("base64");
  bridgeKey = "";
  constructor(readonly base: string) {}

  private derive(info: string) {
    const peer = createPublicKey({ key: { kty: "OKP", crv: "X25519", x: Buffer.from(this.bridgeKey, "base64").toString("base64url") }, format: "jwk" });
    const secret = diffieHellman({ privateKey: this.key.privateKey, publicKey: peer });
    return Buffer.from(hkdfSync("sha256", secret, Buffer.from("lattices-bridge-v1"), Buffer.from(info), 32));
  }

  async pair(capabilities?: string[]) {
    const res = await fetch(`${this.base}/pairing/request`, {
      method: "POST",
      body: JSON.stringify({ deviceID: this.deviceID, deviceName: "Test iPhone", devicePublicKey: this.publicKey, platform: "iOS", appVersion: "1.0", ...(capabilities ? { requestedCapabilities: capabilities } : {}) }),
    });
    const body = await res.json();
    this.bridgeKey = body.bridgePublicKey;
    return { status: res.status, body };
  }

  async call(method: "GET" | "POST", path: string, plaintext?: unknown, tamper?: (h: Record<string, string>) => void, reuse?: { nonce: string; timestamp: string }) {
    const nonce = reuse?.nonce ?? randomUUID().toLowerCase();
    const timestamp = reuse?.timestamp ?? new Date().toISOString();
    let body = Buffer.alloc(0);
    if (plaintext !== undefined) {
      const aad = ["request", method, path, this.deviceID, timestamp, nonce].join("\n");
      const n = randomBytes(12);
      const { ciphertext, tag } = aead.seal(this.derive("encryption"), n, Buffer.from(JSON.stringify(plaintext)), Buffer.from(aad));
      // Swift's JSONEncoder escapes "/" in strings; send it that way.
      body = Buffer.from(JSON.stringify({ sealedBox: Buffer.concat([n, ciphertext, tag]).toString("base64") }).replaceAll("/", "\\/"));
    }
    const canonical = [method, path, this.deviceID, timestamp, nonce, createHash("sha256").update(body).digest("hex")].join("\n");
    const headers: Record<string, string> = {
      "X-Lattices-Device-Id": this.deviceID,
      "X-Lattices-Timestamp": timestamp,
      "X-Lattices-Nonce": nonce,
      "X-Lattices-Signature": createHmac("sha256", this.derive("signing")).update(canonical).digest("base64"),
    };
    tamper?.(headers);
    const res = await fetch(`${this.base}${path}`, { method, headers, body: body.length ? body : undefined });
    const json = await res.json();
    if (res.status !== 200) return { status: res.status, json, nonce, timestamp };
    const sealed = Buffer.from(json.sealedBox, "base64");
    const plain = aead.open(
      this.derive("encryption"),
      sealed.subarray(0, 12),
      sealed.subarray(12, sealed.length - 16),
      sealed.subarray(sealed.length - 16),
      Buffer.from(["response", "200", path, this.deviceID, nonce].join("\n"))
    );
    if (!plain) throw new Error("response did not open");
    return { status: 200, json: JSON.parse(Buffer.from(plain).toString()), nonce, timestamp };
  }
}

const dir = mkdtempSync(join(tmpdir(), "bridge-test-"));
const approvals = new PairingApprovals(5_000, false);
const security = new BridgeSecurity({
  bridgeName: "archie",
  privateKey: generateKeyPairSync("x25519").privateKey,
  devicesPath: join(dir, "devices.json"),
  approve: (req, kind, additions) => approvals.request(req, kind, additions),
});
let bridge: ReturnType<typeof startBridge>;
let base: string;

beforeAll(() => {
  bridge = startBridge({
    hosts: ["127.0.0.1"],
    port: 0,
    name: "archie",
    version: "test",
    trackpadAvailable: () => true,
    hasTmux: () => false,
    log: () => {},
    security,
    approvals,
    snapshot: async () => ({ updatedAt: 1, history: [], questions: [], desktop: { screenCount: 1, visibleWindowCount: 3, sessionCount: 0 } }),
  });
  base = `http://127.0.0.1:${bridge.port}`;
});
afterAll(() => bridge.stop());

/** Approve the next pending pairing once it shows up, as a person would. */
function approveWhenAsked(approve = true) {
  const timer = setInterval(() => {
    const [pending] = approvals.list();
    if (pending) {
      approvals.decide(pending.deviceID, approve);
      clearInterval(timer);
    }
  }, 10);
}

describe("companion bridge", () => {
  test("health advertises the bridge key and fingerprint", async () => {
    const health = await (await fetch(`${base}/health`)).json();
    expect(health).toMatchObject({ ok: true, protocolVersion: "1", port: bridge.port, requestSigningRequired: true, payloadEncryptionRequired: true });
    expect(health.bridgeFingerprint).toBe(fingerprint(health.bridgePublicKey));
    expect(health.bridgeFingerprint).toMatch(/^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$/);
  });

  test("a denied pairing is 403 and grants nothing", async () => {
    const phone = new PhoneClient(base);
    approveWhenAsked(false);
    const { status, body } = await phone.pair();
    expect(status).toBe(403);
    expect(body).toMatchObject({ disposition: "denied", grantedCapabilities: [] });
    expect((await phone.call("GET", "/deck/snapshot")).status).toBe(403);
  });

  test("pair, then signed and encrypted calls round-trip", async () => {
    const phone = new PhoneClient(base);
    approveWhenAsked();
    const pairing = await phone.pair(["deck.read", "deck.perform", "input.trackpad", "screen.preview"]);
    expect(pairing.status).toBe(200);
    expect(pairing.body.disposition).toBe("approved");
    expect(pairing.body.grantedCapabilities).toEqual(["deck.perform", "deck.read", "input.trackpad", "screen.preview"]);

    const snap = await phone.call("GET", "/deck/snapshot");
    expect(snap).toMatchObject({ status: 200, json: { desktop: { visibleWindowCount: 3 } } });

    const perform = await phone.call("POST", "/deck/perform", { actionID: "voice.toggle", payload: {} });
    expect(perform.status).toBe(200);
    expect(perform.json).toMatchObject({ ok: false, summary: "Not available on Linux", suggestedActions: [] });

    const again = await phone.pair(["deck.read"]);
    expect(again.body.disposition).toBe("alreadyTrusted");
  });

  test("replays, stale clocks, bad signatures and unknown devices are refused", async () => {
    const phone = new PhoneClient(base);
    approveWhenAsked();
    await phone.pair();
    const first = await phone.call("GET", "/deck/snapshot");
    expect(first.status).toBe(200);
    expect((await phone.call("GET", "/deck/snapshot", undefined, undefined, { nonce: first.nonce, timestamp: first.timestamp })).status).toBe(401);
    expect((await phone.call("GET", "/deck/snapshot", undefined, undefined, { nonce: randomUUID(), timestamp: new Date(Date.now() - 600_000).toISOString() })).status).toBe(401);
    expect((await phone.call("GET", "/deck/snapshot", undefined, (h) => (h["X-Lattices-Signature"] = "AAAA"))).status).toBe(401);
    expect((await phone.call("GET", "/deck/snapshot", undefined, (h) => (h["X-Lattices-Device-Id"] = "someone-else"))).status).toBe(403);
    expect((await phone.call("GET", "/deck/snapshot", undefined, (h) => delete h["X-Lattices-Nonce"])).json.error).toContain("x-lattices-nonce");
  });

  test("an old pairing without screen.preview cannot preview until it asks again", async () => {
    const phone = new PhoneClient(base);
    approveWhenAsked();
    // No requestedCapabilities: an old app, frozen to the legacy set.
    expect((await phone.pair()).body.grantedCapabilities).toEqual(["deck.perform", "deck.read", "input.trackpad"]);
    expect((await phone.call("POST", "/deck/preview", { maxPixelWidth: 640 })).status).toBe(403);
  });

  test("trust persists across restarts of the bridge", () => {
    const reloaded = new BridgeSecurity({ bridgeName: "archie", privateKey: security.privateKey, devicesPath: join(dir, "devices.json"), approve: async () => false });
    expect(reloaded.trustedDevices().length).toBe(security.trustedDevices().length);
    expect(reloaded.fingerprint).toBe(security.fingerprint);
  });
});

describe("chacha20-poly1305", () => {
  test("RFC 8439 section 2.8.2 vector", () => {
    const key = Buffer.from(Array.from({ length: 32 }, (_, i) => 0x80 + i));
    const nonce = Buffer.from("070000004041424344454647", "hex");
    const aad = Buffer.from("50515253c0c1c2c3c4c5c6c7", "hex");
    const pt = Buffer.from("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.");
    const { ciphertext, tag } = aead.seal(key, nonce, pt, aad);
    expect(Buffer.from(tag).toString("hex")).toBe("1ae10b594f09e26a7e902ecbd0600691");
    expect(Buffer.from(ciphertext).toString("hex").slice(0, 32)).toBe("d31a8d34648e60db7b86afbc53ef7ec2");
    expect(Buffer.from(aead.open(key, nonce, ciphertext, tag, aad)!).equals(pt)).toBe(true);
    expect(aead.open(key, nonce, ciphertext, tag, Buffer.from("other"))).toBeNull();
  });
});

test("Bonjour is advertised only for LAN addresses", async () => {
  const { isLanAddress } = await import("../src/bridge/server.ts");
  expect(["0.0.0.0", "192.168.18.5", "10.0.0.2", "172.20.1.1"].every(isLanAddress)).toBe(true);
  expect(["127.0.0.1", "100.119.71.19", "8.8.8.8", "archie"].some(isLanAddress)).toBe(false);
});
