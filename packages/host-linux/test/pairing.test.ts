// Method scopes, router aliases, and the CLI's signed upgrade checked against
// the shared pairing scheme the gateway uses (bridge/security.ts).
import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BridgeSecurity, BridgeSecurityError, HEADERS, loadOrCreateKeyFile } from "../src/bridge/security.ts";
import { scopeFor } from "../src/pairing.ts";
import { Router } from "../src/router.ts";
import { pairedHost, signUpgrade, signingKey } from "../../../bin/host-pairing.ts";

describe("method scopes", () => {
  test("the scope a method needs", () => {
    expect(scopeFor({ method: "windows.list", access: "read" })).toBe("read");
    expect(scopeFor({ method: "computer.observe", access: "read" })).toBe("read");
    expect(scopeFor({ method: "windows.place", access: "mutate" })).toBe("act");
    expect(scopeFor({ method: "computer.click", access: "mutate" })).toBe("drive");
    expect(scopeFor({ method: "capture.live", access: "read" })).toBe("drive");
    expect(scopeFor({ method: "apps.open", access: "mutate" })).toBe("drive");
  });

  test("the router looks up endpoints through aliases", () => {
    const router = new Router(() => new Set());
    router.register({ method: "windows.place", description: "", access: "mutate", returns: "", handler: () => null });
    expect(router.lookup("window.tile")?.method).toBe("windows.place");
    expect(router.lookup("nope")).toBeUndefined();
  });
});

describe("CLI signer", () => {
  test("the CLI's signed upgrade authenticates; tampering, replay and skew do not", async () => {
    const dir = mkdtempSync(join(tmpdir(), "lattices-pair-"));
    const security = new BridgeSecurity({
      bridgeName: "archie", privateKey: loadOrCreateKeyFile(join(dir, "key.json")), devicesPath: join(dir, "clients.json"),
      approve: async () => true, grant: (requested) => requested ?? [],
    });
    const key = generateKeyPairSync("x25519");
    const publicKey = Buffer.from(key.publicKey.export({ format: "jwk" }).x as string, "base64url").toString("base64");
    const clientID = randomUUID();
    const paired = await security.handlePairing({
      deviceID: clientID, deviceName: "arts-mini", devicePublicKey: publicKey, platform: "darwin",
      requestedCapabilities: ["lattices:windows.list"], node: "arts-mini",
    });
    expect(paired.disposition).toBe("approved");
    const headers = (opts: { timestamp?: string; path?: string } = {}) => {
      const timestamp = opts.timestamp ?? new Date().toISOString();
      const nonce = randomBytes(16).toString("hex");
      return new Headers({
        [HEADERS.deviceID]: clientID,
        [HEADERS.timestamp]: timestamp,
        [HEADERS.nonce]: nonce,
        [HEADERS.signature]: signUpgrade(signingKey(key.privateKey, paired.bridgePublicKey), opts.path ?? "/", clientID, timestamp, nonce),
      });
    };
    const authenticate = (path: string, h: Headers) => security.authorize("GET", path, h, Buffer.alloc(0)).device;

    expect(authenticate("/", headers()).name).toBe("arts-mini");
    const replayed = headers();
    authenticate("/", replayed);
    expect(() => authenticate("/", replayed)).toThrow("nonce was already used");
    expect(() => authenticate("/other", headers())).toThrow("signature is invalid");
    const stale = new Date(Date.now() - 10 * 60_000).toISOString();
    expect(() => authenticate("/", headers({ timestamp: stale }))).toThrow("outside the allowed window");
    const forged = headers();
    forged.set(HEADERS.signature, Buffer.alloc(32).toString("base64"));
    expect(() => authenticate("/", forged)).toThrow(BridgeSecurityError);
  });
});

describe("client pairing store", () => {
  const hosts = {
    "100.64.0.7:9399": { host: "archie", hostPublicKey: "k", hostFingerprint: "F", scope: "mutate" as const, pairedAt: "" },
  };
  test("finds a pairing by address or by the host's tailnet name", () => {
    expect(pairedHost({ host: "100.64.0.7", port: 9399 }, hosts)?.host).toBe("archie");
    expect(pairedHost({ host: "archie", port: 9399 }, hosts)?.host).toBe("archie");
    expect(pairedHost({ host: "archie.tail1234.ts.net", port: 9399 }, hosts)?.host).toBe("archie");
    expect(pairedHost({ host: "archie", port: 19400 }, hosts)).toBeNull();
    expect(pairedHost({ host: "127.0.0.1", port: 9399 }, hosts)).toBeNull();
  });
});
