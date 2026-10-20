import { createConnection } from "node:net";
import { createHash, randomBytes } from "node:crypto";
import { localEndpoint, readLocalToken, validateLocalSocket, type DaemonEndpoint } from "./local-ipc.ts";

/** Persistent, authenticated local event stream; never falls back to TCP. */
export function localEvents(names: string[], onEvent: (event: unknown) => void, onClose: (error?: Error) => void,
  endpoint: DaemonEndpoint = localEndpoint("lattices")): { close(): void } {
  if (!endpoint.socketPath || !endpoint.tokenFile) throw new Error("Events require a private local endpoint");
  const subscription = Buffer.from(JSON.stringify({ id: "events", method: "events.subscribe", params: { events: names } }));
  if (subscription.length > 65535) throw new Error("Event request exceeds limit");
  validateLocalSocket(endpoint.socketPath);
  const token = readLocalToken(endpoint.tokenFile);
  const key = randomBytes(16).toString("base64");
  const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  const socket = createConnection({ path: endpoint.socketPath });
  let buffer = Buffer.alloc(0), upgraded = false, closed = false;
  const finish = (error?: Error) => {
    if (closed) return;
    closed = true; clearTimeout(timer); socket.destroy(); onClose(error);
  };
  const timer = setTimeout(() => finish(new Error("Local event connection timed out")), 3000);
  const send = (opcode: number, payload: Buffer) => {
    if (payload.length > 65535) throw new Error("Event request exceeds limit");
    const mask = randomBytes(4);
    const head = payload.length < 126 ? Buffer.from([0x80 | opcode, 0x80 | payload.length]) : Buffer.from([0x80 | opcode, 0xfe, payload.length >> 8, payload.length & 255]);
    socket.write(Buffer.concat([head, mask, Buffer.from(payload.map((byte, i) => byte ^ mask[i % 4]!))]));
  };
  socket.on("connect", () => { if (closed) return; socket.write([
    "GET / HTTP/1.1", "Host: localhost", "Connection: Upgrade", "Upgrade: websocket", "Sec-WebSocket-Version: 13",
    `Sec-WebSocket-Key: ${key}`, `x-lattices-token: ${token}`, "", "",
  ].join("\r\n")); });
  socket.on("error", finish);
  socket.on("close", () => finish());
  socket.on("data", (chunk: Buffer) => {
    if (closed) return;
    if (buffer.length + chunk.length > 16 * 1024 * 1024) return finish(new Error("Event frame exceeds limit"));
    buffer = Buffer.concat([buffer, chunk]);
    if (!upgraded) {
      const end = buffer.indexOf("\r\n\r\n");
      if (end < 0) { if (buffer.length > 8192) finish(new Error("Upgrade exceeds limit")); return; }
      if (end > 8192) return finish(new Error("Upgrade exceeds limit"));
      const header = buffer.subarray(0, end).toString();
      const returned = header.split("\r\n").filter(line => /^sec-websocket-accept:/i.test(line));
      if (!/^HTTP\/1\.1 101 /.test(header) || returned.length !== 1 || returned[0]!.slice(returned[0]!.indexOf(":") + 1).trim() !== accept) return finish(new Error("Local event authentication failed"));
      buffer = buffer.subarray(end + 4); upgraded = true; clearTimeout(timer);
      send(1, subscription);
    }
    while (buffer.length >= 2) {
      const opcode = buffer[0]! & 15;
      if ((buffer[0]! & 0xf0) !== 0x80 || (buffer[1]! & 0x80)) return finish(new Error("Invalid event frame"));
      let size = buffer[1]! & 127, offset = 2;
      if (size === 126) { if (buffer.length < 4) return; size = buffer.readUInt16BE(2); offset = 4; }
      else if (size === 127) {
        if (buffer.length < 10) return;
        const big = buffer.readBigUInt64BE(2);
        if (big > 16n * 1024n * 1024n) return finish(new Error("Event frame exceeds limit"));
        size = Number(big); offset = 10;
      }
      if (buffer.length < offset + size) return;
      if (![1, 8, 9, 10].includes(opcode) || (opcode >= 8 && size > 125)) return finish(new Error("Invalid event control frame"));
      const payload = buffer.subarray(offset, offset + size); buffer = buffer.subarray(offset + size);
      if (opcode === 8) return finish();
      if (opcode === 9) { send(10, payload); continue; }
      if (opcode !== 1) continue;
      try {
        const message = JSON.parse(payload.toString());
        if (message.id === "events" && message.error) return finish(new Error(typeof message.error === "string" ? message.error : message.error.message ?? "Event subscription failed"));
        if (message.event) onEvent(message);
      }
      catch { return finish(new Error("Invalid local event JSON")); }
    }
  });
  return { close: () => finish() };
}
