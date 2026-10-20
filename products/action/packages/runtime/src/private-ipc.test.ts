import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, existsSync, rmSync, chmodSync, statSync, symlinkSync } from "node:fs";
import { createConnection, createServer, type AddressInfo } from "node:net";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ensurePrivateToken, readPrivateToken } from "./local-security.js";
import { DriveAgentClient } from "./drive-client.js";

const productRoot = resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const nativeBinary = join(productRoot, "native/engine/.build/debug/ActionAgent");
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
async function waitFile(path: string) { for (let i = 0; i < 100; i++) { if (existsSync(path) && (!path.endsWith(".sock") || (statSync(path).mode & 0o777) === 0o600)) return; await sleep(50); } throw new Error(`Missing test endpoint ${path}`); }
async function stop(child: ChildProcess) { if (child.exitCode !== null) return; child.kill("SIGTERM"); await new Promise(resolve => child.once("exit", resolve)); }
function get(socketPath: string, headers: Record<string, string> = {}, path = "/health", body?: unknown): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    const req = request({ socketPath, path, method: body ? "POST" : "GET", headers: { Host: "localhost", ...headers } }, res => {
      const chunks: Buffer[] = []; res.on("data", chunk => chunks.push(chunk)); res.on("end", () => { try { resolve({ status: res.statusCode!, body: JSON.parse(Buffer.concat(chunks).toString()) }); } catch (error) { reject(error); } });
    });
    req.on("error", reject); req.setTimeout(5_000, () => req.destroy(new Error("test timeout"))); req.end(body ? JSON.stringify(body) : undefined);
  });
}
function upgrade(endpoint: string | { host: string; port: number }, headers: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = typeof endpoint === "string" ? createConnection(endpoint) : createConnection(endpoint); let response = "";
    socket.on("connect", () => socket.write(["GET / HTTP/1.1", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", ...headers, "", ""].join("\r\n")));
    socket.on("data", chunk => { response += chunk.toString(); if (response.includes("\r\n\r\n")) { socket.destroy(); resolve(response.split("\r\n")[0]!); } });
    socket.on("close", () => resolve(response)); socket.on("error", reject); socket.setTimeout(6_000, () => { socket.destroy(); reject(new Error("upgrade timeout")); });
  });
}

test("tokens refuse symlinks and public file modes", () => {
  const root = mkdtempSync(join(tmpdir(), "action-token-test-"));
  try {
    const path = join(root, "action.token"); const token = ensurePrivateToken(path);
    assert.equal(readPrivateToken(path), token); assert.equal(ensurePrivateToken(path), token);
    chmodSync(path, 0o644); assert.throws(() => readPrivateToken(path));
    rmSync(path); symlinkSync("/dev/null", path); assert.throws(() => ensurePrivateToken(path));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("native agent denies unauthenticated, foreign origin and Host upgrades and accepts private clients", { skip: process.platform !== "darwin" || !existsSync(nativeBinary) }, async () => {
  const root = mkdtempSync(join(tmpdir(), "action-native-ipc-"));
  const env = { ...process.env, LATTICES_RUNTIME_DIR: root, ACTION_ALLOW_TCP: "0" };
  const child = spawn(nativeBinary, ["--idle-exit-seconds", "60"], { env, stdio: "ignore" });
  const path = join(root, "action.sock");
  try {
    await waitFile(path); const token = readFileSync(join(root, "action.token"), "utf8").trim();
    assert.equal(statSync(root).mode & 0o777, 0o700); assert.equal(statSync(path).mode & 0o777, 0o600);
    for (const headers of [["Host: localhost"], ["Host: localhost", "x-lattices-token: wrong"], ["Host: attacker.example", `x-lattices-token: ${token}`], ["Host: localhost", `x-lattices-token: ${token}`, "Origin: https://example.com"], ["Host: localhost", `x-lattices-token: ${token}`, `x-lattices-token: ${token}`]]) {
      assert.doesNotMatch(await upgrade(path, headers), /101/);
    }
    assert.match(await upgrade(path, ["Host: localhost", `x-lattices-token: ${token}`]), /101/);
    const duplicate = spawn(nativeBinary, [], { env, stdio: "ignore" });
    await new Promise(resolve => duplicate.once("exit", resolve)); assert.notEqual(duplicate.exitCode, 0); assert.ok(existsSync(path));
    const reply = JSON.parse(execFileSync(join(productRoot, "native/engine/.build/debug/ActionAgentCLI"), ["ping"], { env, encoding: "utf8" }));
    assert.equal(reply.ok, true);
    const previous = process.env.LATTICES_RUNTIME_DIR; process.env.LATTICES_RUNTIME_DIR = root;
    try { const client = new DriveAgentClient({ launcherPath: "/must-not-launch" }); await client.status(); client.close(); }
    finally { if (previous === undefined) delete process.env.LATTICES_RUNTIME_DIR; else process.env.LATTICES_RUNTIME_DIR = previous; }
    try { const sockets = execFileSync("/usr/sbin/lsof", ["-a", "-p", String(child.pid), "-iTCP", "-sTCP:LISTEN"], { encoding: "utf8" }); assert.equal(sockets.trim(), ""); } catch (error) { assert.equal((error as { status: number }).status, 1); }
  } finally { await stop(child); rmSync(root, { recursive: true, force: true }); }
});

test("explicit native TCP compatibility still requires auth and blocks browser origins", { timeout: 15_000, skip: process.platform !== "darwin" || !existsSync(nativeBinary) }, async () => {
  const reserve = createServer();
  await new Promise<void>(resolve => reserve.listen(0, "127.0.0.1", resolve));
  const port = (reserve.address() as AddressInfo).port;
  await new Promise<void>(resolve => reserve.close(() => resolve()));
  const root = mkdtempSync(join(tmpdir(), "action-tcp-auth-"));
  const env = { ...process.env, LATTICES_RUNTIME_DIR: root, ACTION_ALLOW_TCP: "1" };
  const child = spawn(nativeBinary, ["--port", String(port), "--idle-exit-seconds", "60"], { env, stdio: "ignore" });
  try {
    await waitFile(join(root, "action.token"));
    const token = readPrivateToken(join(root, "action.token"));
    const endpoint = { host: "127.0.0.1", port };
    const good = [`Host: 127.0.0.1:${port}`, `x-lattices-token: ${token}`];
    for (let i = 0; ; i++) {
      try { assert.match(await upgrade(endpoint, good), /101/); break; }
      catch (error) { if (i >= 50) throw error; await sleep(50); }
    }
    assert.equal(existsSync(join(root, "action.sock")), false);
    for (const headers of [[good[0]!], [...good, "Origin: null"], ["Host: attacker.example", good[1]!]]) {
      assert.doesNotMatch(await upgrade(endpoint, headers), /101/);
    }
    const reply = JSON.parse(execFileSync(join(productRoot, "native/engine/.build/debug/ActionAgentCLI"), ["--port", String(port), "ping"], { env, encoding: "utf8" }));
    assert.equal(reply.ok, true);
    // An unauthenticated peer that never finishes its upgrade is evicted.
    await new Promise<void>((resolve, reject) => {
      const socket = createConnection(endpoint);
      socket.on("close", () => resolve()); socket.on("error", reject);
      socket.setTimeout(7_000, () => { socket.destroy(); reject(new Error("Unauthenticated peer was not timed out")); });
    });
  } finally { await stop(child); rmSync(root, { recursive: true, force: true }); }
});

test("Chrome native messaging roundtrip uses authenticated private socket with no browser Origin", async () => {
  const root = mkdtempSync(join(tmpdir(), "action-chrome-ipc-"));
  const env = { ...process.env, LATTICES_RUNTIME_DIR: root };
  const child = spawn(process.execPath, [join(productRoot, "packages/chrome-companion/scripts/bridge-server.mjs")], { env, stdio: "ignore" });
  let host: ChildProcess | undefined;
  try {
    const path = join(root, "action-chrome.sock"); await waitFile(path);
    const token = readFileSync(join(root, "action-chrome.token"), "utf8").trim(); const headers = { "x-lattices-token": token };
    assert.equal((await get(path)).status, 401); assert.equal((await get(path, { ...headers, Origin: "https://example.com" })).status, 401);
    assert.equal((await get(path, headers)).body.connected, false);
    host = spawn(process.execPath, [join(productRoot, "packages/chrome-companion/scripts/native-host.mjs")], { env, stdio: ["pipe", "pipe", "pipe"] });
    host.stdout!.on("data", chunk => {
      const data = Buffer.from(chunk); if (data.length < 4) return;
      const message = JSON.parse(data.subarray(4, 4 + data.readUInt32LE(0)).toString());
      const reply = Buffer.from(JSON.stringify({ id: message.id, response: { ok: true, result: { transport: "native-messaging" } } }));
      const header = Buffer.alloc(4); header.writeUInt32LE(reply.length); host!.stdin!.write(Buffer.concat([header, reply]));
    });
    for (let i = 0; i < 50; i++) { if ((await get(path, headers)).body.connected) break; await sleep(50); }
    const response = await get(path, headers, "/rpc", { method: "tabs.list" });
    assert.equal(response.status, 200); assert.equal(response.body.result.transport, "native-messaging");
    const oversize = Buffer.alloc(4); oversize.writeUInt32LE(1_048_577); host.stdin!.write(oversize);
    await new Promise(resolve => host!.once("exit", resolve)); assert.equal(host.exitCode, 1);
  } finally { if (host) await stop(host); await stop(child); rmSync(root, { recursive: true, force: true }); }
});

test("companion starts private-only and authenticates every HTTP endpoint", async () => {
  const root = mkdtempSync(join(tmpdir(), "action-companion-ipc-"));
  const support = join(root, "support");
  const env = { ...process.env, LATTICES_RUNTIME_DIR: root, ACTION_SUPPORT_DIRECTORY: support, ACTION_COMPANION_PORT: "4320", ACTION_COMPANION_ALLOW_TCP: "0" };
  const child = spawn(process.execPath, [join(productRoot, "packages/companion/src/server.ts")], { env, stdio: "ignore" });
  try {
    const path = join(support, "runtime/companion.sock"); await waitFile(path);
    const token = readFileSync(join(root, "action-companion.token"), "utf8").trim();
    assert.equal(statSync(path).mode & 0o777, 0o600);
    for (const route of ["/health", "/v1/status", "/v1/secrets/status", "/v1/jobs"]) assert.equal((await get(path, {}, route)).status, 401);
    assert.equal((await get(path, { "x-lattices-token": token, Origin: "https://example.com" })).status, 401);
    assert.equal((await get(path, { "x-lattices-token": token, Host: "attacker.example" })).status, 403);
    assert.equal((await get(path, { "x-lattices-token": token })).body.ok, true);
    if (process.platform === "darwin") {
      try { const sockets = execFileSync("/usr/sbin/lsof", ["-a", "-p", String(child.pid), "-iTCP", "-sTCP:LISTEN"], { encoding: "utf8" }); assert.equal(sockets.trim(), ""); }
      catch (error) { assert.equal((error as { status: number }).status, 1); }
    }
  } finally { await stop(child); rmSync(root, { recursive: true, force: true }); }
});
