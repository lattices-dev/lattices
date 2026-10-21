#!/usr/bin/env bun
// Chrome native messaging owns stdio. Never log to stdout.
import WebSocket from "ws";
import { chromeCompanionSocket, chromeCompanionToken } from "../../runtime/src/chrome-companion-ipc.ts";
import { readPrivateToken } from "../../runtime/src/local-security.ts";

const ws = new WebSocket(`ws+unix://${chromeCompanionSocket()}:/chrome-companion`, {
  headers: { Host: "localhost", "x-lattices-token": readPrivateToken(chromeCompanionToken()) },
  handshakeTimeout: 5_000, maxPayload: 1_048_576,
});
let buffer = Buffer.alloc(0);
let queue = [];
process.stdin.on("data", chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  while (buffer.length >= 4) {
    const size = buffer.readUInt32LE(0);
    if (size > 1_048_576) return process.exit(1);
    if (buffer.length < size + 4) return;
    const text = buffer.subarray(4, 4 + size).toString("utf8");
    buffer = buffer.subarray(4 + size);
    try { JSON.parse(text); } catch { return process.exit(1); }
    if (ws.readyState === WebSocket.OPEN) ws.send(text);
    else { if (queue.length >= 16) return process.exit(1); queue.push(text); }
  }
});
ws.on("open", () => { for (const text of queue) ws.send(text); queue = []; });
ws.on("message", data => {
  const payload = Buffer.from(data);
  if (payload.length > 1_048_576) return process.exit(1);
  const header = Buffer.alloc(4); header.writeUInt32LE(payload.length);
  process.stdout.write(Buffer.concat([header, payload]));
});
ws.on("error", () => process.exit(1));
ws.on("close", () => process.exit(0));
process.stdin.on("end", () => { ws.close(); process.exit(0); });
