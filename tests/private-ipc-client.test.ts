import { expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { createHash } from "node:crypto";
import { createServer as createHTTPServer, type IncomingHttpHeaders } from "node:http";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { daemonCallTo, daemonEndpoint } from "../packages/desktop-client/daemon-client.ts";
import { legacyTokenFile, localEndpoint, localTokenFile, sharedTokenFile } from "../packages/desktop-client/local-ipc.ts";
import { localEvents } from "../packages/desktop-client/local-events.ts";
import { localHTTPGet } from "../packages/desktop-client/local-http.ts";
import { parsePairOptions } from "../bin/cli/hosts.ts";

const token = "a".repeat(64);
function frame(opcode: number, payload: Buffer | string, final = true): Buffer {
  const data = Buffer.from(payload), header = Buffer.alloc(data.length < 126 ? 2 : data.length < 65536 ? 4 : 10);
  header[0] = (final ? 128 : 0) | opcode;
  header[1] = header.length === 2 ? data.length : header.length === 4 ? 126 : 127;
  if (header.length === 4) header.writeUInt16BE(data.length, 2);
  if (header.length === 10) header.writeBigUInt64BE(BigInt(data.length), 2);
  return Buffer.concat([header, data]);
}

async function fixture(onFrame: (socket: Socket, opcode: number, payload: Buffer) => void) {
  const directory = mkdtempSync("/tmp/lats-client-");
  chmodSync(directory, 0o700);
  const endpoint = localEndpoint("lattices", { LATTICES_RUNTIME_DIR: directory });
  writeFileSync(endpoint.tokenFile!, token, { mode: 0o600 });
  const sockets = new Set<Socket>();
  const server = createServer(socket => {
    sockets.add(socket); socket.on("close", () => sockets.delete(socket)); socket.on("error", () => {});
    let buffer = Buffer.alloc(0), upgraded = false;
    socket.on("data", chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded) {
        const end = buffer.indexOf("\r\n\r\n"); if (end < 0) return;
        const header = buffer.subarray(0, end).toString();
        expect(header).toContain("Host: localhost\r\n");
        expect(header).toContain(`x-lattices-token: ${token}`);
        const key = /^Sec-WebSocket-Key: (.*)$/mi.exec(header)![1]!.trim();
        const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
        socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
        buffer = buffer.subarray(end + 4); upgraded = true;
      }
      while (buffer.length >= 2) {
        expect(buffer[1]! & 128).toBe(128);
        let size = buffer[1]! & 127, offset = 2;
        if (size === 126) { if (buffer.length < 4) return; size = buffer.readUInt16BE(2); offset = 4; }
        else if (size === 127) { if (buffer.length < 10) return; size = Number(buffer.readBigUInt64BE(2)); offset = 10; }
        if (buffer.length < offset + 4 + size) return;
        const mask = buffer.subarray(offset, offset + 4), payload = Buffer.from(buffer.subarray(offset + 4, offset + 4 + size));
        for (let i = 0; i < size; i++) payload[i] = payload[i]! ^ mask[i % 4]!;
        const opcode = buffer[0]! & 15; buffer = buffer.subarray(offset + 4 + size);
        onFrame(socket, opcode, payload);
      }
    });
  });
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(endpoint.socketPath, resolve); });
  chmodSync(endpoint.socketPath!, 0o600);
  return { endpoint, close: async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    rmSync(directory, { recursive: true, force: true });
  } };
}

test("private client handles fragmented UTF-8, interleaved ping, and large masked requests", async () => {
  const value = "🙂" + "x".repeat(150_000);
  let response = Buffer.alloc(0);
  const server = await fixture((socket, opcode, payload) => {
    if (opcode === 10) {
      expect(payload.toString()).toBe("alive");
      socket.write(frame(0, response.subarray(3)));
      return;
    }
    const request = JSON.parse(payload.toString());
    expect(request.params.text).toBe(value);
    const json = JSON.stringify({ id: request.id, result: value });
    const bytes = Buffer.from(json), split = bytes.indexOf(Buffer.from("🙂")) + 1;
    response = bytes.subarray(split);
    socket.write(Buffer.concat([frame(1, bytes.subarray(0, split), false), frame(0, response.subarray(0, 3), false), frame(9, "alive")]));
  });
  try { expect(await daemonCallTo(server.endpoint, "echo", { text: value })).toBe(value); }
  finally { await server.close(); }
});

test("private client rejects oversized, masked, and invalid control frames", async () => {
  for (const bytes of [Buffer.from([0x81, 127, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), Buffer.from([0x81, 128]), Buffer.from([0x89, 126])]) {
    const server = await fixture(socket => socket.write(bytes));
    try { await expect(daemonCallTo(server.endpoint, "status")).rejects.toThrow(/frame/i); }
    finally { await server.close(); }
  }
});

test("private client cancellation closes the socket and unsafe credentials fail closed", async () => {
  const server = await fixture(() => {});
  try {
    const controller = new AbortController();
    const call = daemonCallTo(server.endpoint, "status", null, 5000, controller.signal);
    controller.abort(new Error("cancelled"));
    await expect(call).rejects.toThrow("cancelled");
    chmodSync(server.endpoint.tokenFile!, 0o644);
    await expect(daemonCallTo(server.endpoint, "status")).rejects.toThrow("private");
    expect(daemonEndpoint({})).toHaveProperty("socketPath");
    expect(daemonEndpoint({ LATTICES_DAEMON_HOST: "remote" }).tokenFile).toBeUndefined();
  } finally { await server.close(); }
});

test("explicit TCP endpoints require a separate opt-in for local credentials", async () => {
  expect(daemonEndpoint({})).toHaveProperty("socketPath");
  for (const host of ["127.0.0.1", "localhost", "::1", "remote.example"]) {
    const endpoint = daemonEndpoint({ LATTICES_DAEMON_HOST: host });
    expect(endpoint.socketPath).toBeUndefined();
    expect(endpoint.tokenFile).toBeUndefined();
  }
  expect(daemonEndpoint({ LATTICES_DAEMON_PORT: "12345" }).tokenFile).toBeUndefined();
  expect(daemonEndpoint({ LATTICES_ALLOW_LOOPBACK_TCP: "1" }).tokenFile).toBeDefined();
  expect(daemonEndpoint({ LATTICES_ALLOW_LOOPBACK_TCP: "1", LATTICES_DAEMON_HOST: "remote.example" }).tokenFile).toBeUndefined();
  // Reject a caller's accidental remote credential attachment before reading
  // the file (and before DNS/connect), even when the file does not exist.
  await expect(daemonCallTo({ host: "remote.invalid", port: 9399, tokenFile: "/missing/private-token" }, "voice.status"))
    .rejects.toThrow("Refusing to send a local capability to a remote host");
});

test("real TCP tunnel upgrades never contain local or Speech capabilities; private and opted-in TCP do", async () => {
  const home = mkdtempSync("/tmp/lats-tunnel-");
  chmodSync(home, 0o700);
  const runtime = join(home, "run");
  mkdirSync(runtime, { mode: 0o700 });
  const speechDirectory = join(home, "Library/Application Support/Speech/RPC");
  mkdirSync(speechDirectory, { recursive: true, mode: 0o700 });
  const speechToken = "s".repeat(64);
  writeFileSync(join(speechDirectory, "capability"), speechToken, { mode: 0o600 });
  const tokenFile = join(runtime, "lattices.token");
  writeFileSync(tokenFile, token, { mode: 0o600 });

  // A fresh process gives the client its own HOME for the legacy Speech
  // capability; these tests never read or alter the user's real credentials.
  const clientModule = new URL("../packages/desktop-client/daemon-client.ts", import.meta.url).href;
  const probe = `import { daemonEndpoint, daemonCallTo } from ${JSON.stringify(clientModule)};
    const endpoint = process.env.TEST_ENDPOINT ? JSON.parse(process.env.TEST_ENDPOINT) : daemonEndpoint();
    try { await daemonCallTo(endpoint, process.env.TEST_METHOD, null, 1500); throw new Error("Expected fixture rejection"); }
    catch (error) { if (!error.message.includes("WebSocket upgrade failed")) throw error; }`;

  try {
    for (const mode of ["tunnel", "direct-tunnel", "compatibility", "private"] as const) {
      let headers: IncomingHttpHeaders | undefined;
      const server = createHTTPServer();
      server.on("upgrade", (request, socket) => {
        headers = request.headers;
        socket.end("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
      });
      const socketPath = join(runtime, "lattices.sock");
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        if (mode === "private") server.listen(socketPath, resolve);
        else server.listen(0, "127.0.0.1", resolve);
      });
      if (mode === "private") chmodSync(socketPath, 0o600);
      const port = mode === "private" ? 0 : (server.address() as { port: number }).port;
      // Deliberately unreadable-by-policy token proves a tunnel does not even
      // consult the local credential, while an opted-in connection does.
      chmodSync(tokenFile, mode.includes("tunnel") ? 0o644 : 0o600);
      try {
        for (const method of ["voice.status", "speech.status"]) {
          const env = { ...process.env, HOME: home, LATTICES_RUNTIME_DIR: runtime,
            LATTICES_DAEMON_HOST: mode === "private" ? "" : "127.0.0.1",
            LATTICES_DAEMON_PORT: mode === "private" ? "" : String(port),
            LATTICES_ALLOW_LOOPBACK_TCP: mode === "compatibility" ? "1" : "",
            TEST_ENDPOINT: mode === "direct-tunnel" ? JSON.stringify({ host: "127.0.0.1", port }) : "",
            TEST_METHOD: method };
          await new Promise<void>((resolve, reject) => {
            const child = spawn(process.execPath, ["--eval", probe], { env, stdio: ["ignore", "pipe", "pipe"] });
            let output = "";
            child.stdout.on("data", data => { output += data; });
            child.stderr.on("data", data => { output += data; });
            child.once("error", reject);
            child.once("exit", code => code === 0 ? resolve() : reject(new Error(`Probe failed (${code}): ${output}`)));
          });
          expect(headers).toBeDefined();
          const authorizedLocal = mode === "private" || mode === "compatibility";
          expect(headers!["x-lattices-token"]).toBe(authorizedLocal ? token : undefined);
          expect(headers!["x-lattices-speech-token"]).toBe(authorizedLocal ? speechToken : undefined);
        }
      } finally {
        await new Promise<void>(resolve => server.close(() => resolve()));
      }
    }
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("event client reports subscription denial and rejects oversized ping", async () => {
  for (const reply of [frame(1, JSON.stringify({ id: "events", error: "denied" })), frame(9, Buffer.alloc(126))]) {
    const server = await fixture(socket => socket.write(reply));
    try {
      const error = await new Promise<Error | undefined>(resolve => localEvents(["windows"], () => {}, resolve, server.endpoint));
      expect(error?.message).toMatch(/denied|control/);
    } finally { await server.close(); }
  }
});

test("pair options carry only exact requested grants and do not mistake a grant for a host", () => {
  expect(parsePairOptions(["--grant", "action:status", "mini", "--grant=blink:notes.list", "--grant", "action:status"]))
    .toEqual({ name: "mini", scope: "read", grants: ["action:status", "blink:notes.list"] });
  expect(parsePairOptions(["mini", "--drive"])).toEqual({ name: "mini", scope: "drive" });
  for (const args of [["--grant"], ["--grant", "action:*"], ["--grant", "action:status", "--drive"], ["--read-only", "--drive"]]) expect(() => parsePairOptions(args)).toThrow();
});

test("HTTP companion health uses private credentials and rejects unsafe token permissions", async () => {
  const directory = mkdtempSync("/tmp/lats-http-");
  chmodSync(directory, 0o700);
  const previous = process.env.LATTICES_RUNTIME_DIR;
  process.env.LATTICES_RUNTIME_DIR = directory;
  const endpoint = localEndpoint("action-chrome");
  writeFileSync(endpoint.tokenFile!, token, { mode: 0o600 });
  const server = createHTTPServer((request, response) => {
    expect(request.headers.host).toBe("localhost");
    expect(request.headers["x-lattices-token"]).toBe(token);
    expect(request.headers.origin).toBeUndefined();
    expect(request.url).toBe("/health");
    response.end(JSON.stringify({ ok: true }));
  });
  try {
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(endpoint.socketPath, resolve); });
    chmodSync(endpoint.socketPath!, 0o600);
    expect(await localHTTPGet("action-chrome", "/health")).toEqual({ ok: true });
    chmodSync(endpoint.tokenFile!, 0o644);
    await expect(localHTTPGet("action-chrome", "/health")).rejects.toThrow("private");
  } finally {
    if (previous === undefined) delete process.env.LATTICES_RUNTIME_DIR;
    else process.env.LATTICES_RUNTIME_DIR = previous;
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Lattices endpoints share lattices.token; a live legacy per-service token is used during the transition", () => {
  const directory = mkdtempSync("/tmp/lats-shared-");
  chmodSync(directory, 0o700);
  const env = { LATTICES_RUNTIME_DIR: directory };
  try {
    const shared = join(directory, "lattices.token");
    expect(sharedTokenFile(env)).toBe(shared);
    for (const product of ["lattices", "gateway", "companion"]) expect(localEndpoint(product, env).tokenFile).toBe(shared);
    // Separately shipped products keep their own credential.
    for (const product of ["action", "action-chrome", "speech", "voice"]) expect(localTokenFile(product, env)).toBe(join(directory, `${product}.token`));
    // An older companion bridge or gateway still owns its per-service file.
    for (const product of ["companion", "gateway"]) {
      writeFileSync(legacyTokenFile(product, env), token, { mode: 0o600 });
      expect(localEndpoint(product, env).tokenFile).toBe(join(directory, `${product}.token`));
    }
    expect(localEndpoint("lattices", env).tokenFile).toBe(shared);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
