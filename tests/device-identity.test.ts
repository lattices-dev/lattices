import { expect, test } from "bun:test";
import { createPublicKey, generateKeyPairSync, randomUUID } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { deviceIdentity, identityPath, legacyKeyFiles, rawPublicKey } from "../packages/desktop-client/device-identity.ts";

function withBase(run: (base: string) => void) {
  const base = mkdtempSync(join(tmpdir(), "device-identity-"));
  try { run(base); } finally { rmSync(base, { recursive: true, force: true }); }
}

function put(path: string, data: string | Buffer) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, data, { mode: 0o600 });
}

const jwk = () => generateKeyPairSync("x25519").privateKey.export({ format: "jwk" }) as Record<string, string>;
const publicOf = (key: Record<string, string>) => Buffer.from(key.x!, "base64url").toString("base64");

test("a new machine gets one private identity that stays stable", () => withBase((base) => {
  const first = deviceIdentity(base);
  const path = identityPath(base);
  expect(statSync(path).mode & 0o777).toBe(0o600);
  expect(statSync(dirname(path)).mode & 0o777).toBe(0o700);
  const second = deviceIdentity(base);
  expect(second.publicKey).toBe(first.publicKey);
  expect(second.id).toBe(first.id);
  expect(first.publicKey).toBe(rawPublicKey(first.privateKey).toString("base64"));
  expect(first.fingerprint).toMatch(/^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$/);
  const stored = JSON.parse(readFileSync(path, "utf8"));
  expect(stored).toMatchObject({ version: 1, privateKey: { kty: "OKP", crv: "X25519" } });
}));

test("the gateway key is kept when a client has pinned it, with the client id", () => withBase((base) => {
  const files = legacyKeyFiles(base);
  const gateway = jwk(), client = jwk();
  put(files.gatewayKey, JSON.stringify(gateway));
  put(files.gatewayClients, JSON.stringify([{ id: "peer" }]));
  put(files.companionKey, Buffer.alloc(32, 7));
  put(files.hostBridgeKey, JSON.stringify(jwk()));
  put(files.client, JSON.stringify({ id: "client-id", name: "mini", privateKey: client }));
  put(files.visitKey, Buffer.alloc(32, 9));
  const identity = deviceIdentity(base);
  expect(identity.publicKey).toBe(publicOf(gateway));
  expect(identity.id).toBe("client-id");
  expect(identity.name).toBe("mini");
  for (const path of [files.gatewayKey, files.companionKey, files.hostBridgeKey, files.client, files.visitKey]) expect(existsSync(path)).toBe(false);
  expect(existsSync(files.gatewayClients)).toBe(true);
}));

test("an unpinned gateway key yields to the companion bridge key", () => withBase((base) => {
  const files = legacyKeyFiles(base);
  put(files.gatewayKey, JSON.stringify(jwk()));
  put(files.gatewayClients, "[]");
  const raw = generateKeyPairSync("x25519").privateKey;
  const d = Buffer.from((raw.export({ format: "jwk" }) as { d: string }).d, "base64url");
  put(files.companionKey, d);
  const identity = deviceIdentity(base);
  expect(identity.publicKey).toBe(rawPublicKey(createPublicKey(raw)).toString("base64"));
}));

test("a Linux host keeps its bridge key when no gateway client pinned one", () => withBase((base) => {
  const files = legacyKeyFiles(base);
  const bridge = jwk();
  put(files.hostBridgeKey, JSON.stringify(bridge));
  put(files.visitKey, Buffer.alloc(32, 3));
  expect(deviceIdentity(base).publicKey).toBe(publicOf(bridge));
}));

test("unsafe or malformed identity files are refused, never replaced", () => withBase((base) => {
  const path = identityPath(base);
  deviceIdentity(base);
  const good = readFileSync(path, "utf8");
  chmodSync(path, 0o644);
  expect(() => deviceIdentity(base)).toThrow("Unsafe device identity");
  chmodSync(path, 0o600);
  put(path, good.replace("X25519", "Ed25519"));
  expect(() => deviceIdentity(base)).toThrow("Malformed device identity");
  rmSync(path);
  const target = join(base, randomUUID());
  put(target, good);
  symlinkSync(target, path);
  expect(() => deviceIdentity(base)).toThrow();
}));
