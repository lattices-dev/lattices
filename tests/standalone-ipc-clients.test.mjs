import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash } from "node:crypto";
import { createServer } from "node:net";
import { chmodSync, copyFileSync, mkdtempSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const token = "a".repeat(64);
const envKeys = ["LATTICES_RUNTIME_DIR", "LATTICES_DAEMON_HOST", "LATTICES_DAEMON_PORT", "LATTICES_ALLOW_LOOPBACK_TCP"];

// Import only the actual shipped .mjs file from outside the repository. This
// catches accidental dependencies on unpublished files or a TypeScript loader.
async function standalone(path, fn) {
  const root = mkdtempSync("/tmp/lats-standalone-");
  const target = join(root, "client.mjs");
  copyFileSync(resolve(path), target);
  try { await fn(await import(pathToFileURL(target).href)); }
  finally { rmSync(root, { recursive: true, force: true }); }
}

async function fixture(fn, { tcp = false, badAccept = false } = {}) {
  const directory = mkdtempSync("/tmp/lats-sdk-");
  chmodSync(directory, 0o700);
  const saved = Object.fromEntries(envKeys.map(key => [key, process.env[key]]));
  for (const key of envKeys) delete process.env[key];
  process.env.LATTICES_RUNTIME_DIR = directory;
  const socketPath = join(directory, "lattices.sock"), tokenFile = join(directory, "lattices.token");
  writeFileSync(tokenFile, token, { mode: 0o600 });
  const peers = new Set(), headers = [], requests = [];
  const server = createServer(socket => {
    peers.add(socket); socket.on("close", () => peers.delete(socket)); socket.on("error", () => {});
    let buffer = Buffer.alloc(0), upgraded = false;
    socket.on("data", chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded) {
        const end = buffer.indexOf("\r\n\r\n"); if (end < 0) return;
        const header = buffer.subarray(0, end).toString();
        headers.push(header); buffer = buffer.subarray(end + 4);
        if (!tcp && !header.includes(`x-lattices-token: ${token}\r\n`)) {
          socket.end("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return;
        }
        const key = /^Sec-WebSocket-Key: (.*)$/mi.exec(header)[1].trim();
        const accept = badAccept ? "wrong" : createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
        socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
        upgraded = true;
      }
      while (buffer.length >= 2) {
        assert.ok(buffer[1] & 128, "client frames must be masked");
        let length = buffer[1] & 127, offset = 2;
        if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
        else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
        if (buffer.length < offset + 4 + length) return;
        const mask = buffer.subarray(offset, offset + 4), payload = Buffer.from(buffer.subarray(offset + 4, offset + 4 + length));
        for (let i = 0; i < length; i++) payload[i] ^= mask[i % 4];
        buffer = buffer.subarray(offset + 4 + length);
        const request = JSON.parse(payload.toString()); requests.push(request);
        const reply = Buffer.from(JSON.stringify({ id: request.id, result: { privateIPC: !tcp, method: request.method } }));
        assert.ok(reply.length < 126);
        socket.write(Buffer.concat([Buffer.from([0x81, reply.length]), reply]));
      }
    });
  });
  await new Promise((resolve, reject) => { server.once("error", reject); tcp ? server.listen(0, "127.0.0.1", resolve) : server.listen(socketPath, resolve); });
  if (!tcp) chmodSync(socketPath, 0o600);
  try { await fn({ directory, socketPath, tokenFile, headers, requests, port: server.address().port }); }
  finally {
    for (const peer of peers) peer.destroy();
    await new Promise(resolve => server.close(resolve));
    for (const key of envKeys) saved[key] === undefined ? delete process.env[key] : process.env[key] = saved[key];
    rmSync(directory, { recursive: true, force: true });
  }
}

for (const [name, path] of [
  ["published SDK", "packages/npm/sdk/cua.mjs"],
  ["Pi extension", "packages/pi-lattices/daemon-client.mjs"],
]) {
  test(`${name}: standalone file defaults to authenticated private IPC`, () => standalone(path, client => fixture(async ({ headers, requests }) => {
    assert.deepEqual(await client.daemonCall("daemon.status"), { privateIPC: true, method: "daemon.status" });
    assert.match(headers[0], /Host: localhost\r\n/);
    assert.ok(headers[0].includes(`x-lattices-token: ${token}\r\n`));
    assert.doesNotMatch(headers[0], /\r\nOrigin:/i);
    if (name === "published SDK") assert.ok(requests[0].deadline > Date.now());
  })));

  test(`${name}: unsafe credentials and socket permissions fail before connecting`, () => standalone(path, client => fixture(async ({ tokenFile, socketPath, headers }) => {
    chmodSync(tokenFile, 0o644);
    await assert.rejects(client.daemonCall("daemon.status"), /private/);
    chmodSync(tokenFile, 0o600); chmodSync(socketPath, 0o666);
    await assert.rejects(client.daemonCall("daemon.status"), /private/);
    chmodSync(socketPath, 0o600);
    const target = `${tokenFile}.real`; writeFileSync(target, token, { mode: 0o600 });
    unlinkSync(tokenFile); symlinkSync(target, tokenFile);
    await assert.rejects(client.daemonCall("daemon.status"));
    assert.equal(headers.length, 0);
  })));

  test(`${name}: incorrect token is rejected before an RPC is sent`, () => standalone(path, client => fixture(async ({ tokenFile, requests }) => {
    writeFileSync(tokenFile, "b".repeat(64));
    await assert.rejects(client.daemonCall("daemon.status"), /WebSocket upgrade failed/);
    assert.equal(requests.length, 0);
  })));

  test(`${name}: invalid WebSocket accept is rejected before an RPC is sent`, () => standalone(path, client => fixture(async ({ requests }) => {
    await assert.rejects(client.daemonCall("daemon.status"), /WebSocket upgrade failed/);
    assert.equal(requests.length, 0);
  }, { badAccept: true })));

  test(`${name}: missing private endpoint never falls back to a network listener`, () => standalone(path, client => fixture(async ({ headers }) => {
    await assert.rejects(client.daemonCall("daemon.status"), { code: "ENOENT" });
    assert.equal(headers.length, 0);
  }, { tcp: true })));
}

test("Pi explicit TCP/tunnel target never reads or sends local credentials", () => standalone("packages/pi-lattices/daemon-client.mjs", client => fixture(async ({ tokenFile, port, headers }) => {
  chmodSync(tokenFile, 0o644); // The remote path must not even try reading this.
  assert.deepEqual(await client.daemonCall("daemon.status", null, { host: "127.0.0.1", port }), { privateIPC: false, method: "daemon.status" });
  assert.doesNotMatch(headers[0], /x-lattices-token|x-lattices-speech-token/i);
  assert.ok(!headers[0].includes(token));
}, { tcp: true })));

test("Pi explicit compatibility mode authenticates only a loopback endpoint", () => standalone("packages/pi-lattices/daemon-client.mjs", client => fixture(async ({ port, headers }) => {
  process.env.LATTICES_ALLOW_LOOPBACK_TCP = "1";
  await client.daemonCall("daemon.status", null, { host: "127.0.0.1", port });
  assert.ok(headers[0].includes(`x-lattices-token: ${token}\r\n`));
  assert.equal(client.daemonConfig({ host: "remote.example", port }).tokenFile, undefined);
}, { tcp: true })));
