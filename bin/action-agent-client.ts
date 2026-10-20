// Authenticated WebSocket client over the Action private Unix socket
// Same framing approach as daemon-client.ts; the Action protocol differs:
// request  { id, method, params: { [key]: string } }
// response { id, ok, result?: { [key]: string }, error?: string }
// Zero npm dependencies.

import { createConnection, type Socket } from "node:net";
import { randomBytes, createHash } from "node:crypto";
import { localEndpoint, readLocalToken, validateLocalSocket } from "../packages/desktop-client/local-ipc";

const MAX_FRAME_SIZE = 16 * 1024 * 1024;

interface ParsedFrame {
  payload: string;
  rest: Buffer<ArrayBuffer>;
}

export type ActionAgentResult = {
  ok: boolean;
  result?: Record<string, string>;
  error?: string;
};

/**
 * Send a request to the Action agent and return the response.
 * Params values are coerced to strings — the native protocol is [String: String].
 */
export async function actionAgentCall(
  method: string,
  params?: Record<string, unknown> | null,
  timeoutMs = 3000
): Promise<ActionAgentResult> {
  const endpoint = localEndpoint("action");
  if (process.env.ACTION_SOCKET_PATH) endpoint.socketPath = process.env.ACTION_SOCKET_PATH;
  const token = readLocalToken(endpoint.tokenFile!);
  validateLocalSocket(endpoint.socketPath!);
  const id = randomBytes(8).toString("hex");
  const stringParams: Record<string, string> = {};
  for (const [key, value] of Object.entries(params ?? {})) {
    if (value === null || value === undefined) continue;
    stringParams[key] = typeof value === "string" ? value : JSON.stringify(value);
  }
  stringParams.authToken = token;
  stringParams.protocolVersion = "2";
  const request = JSON.stringify({ id, method, params: stringParams });

  return new Promise((resolve, reject) => {
    const socket = createConnection(endpoint.socketPath!);
    const key = randomBytes(16).toString("base64");
    let settled = false;
    let buffer = Buffer.alloc(0);
    let upgraded = false;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        socket.destroy();
        reject(new Error("Action agent request timed out"));
      }
    }, timeoutMs);

    const cleanup = () => {
      clearTimeout(timer);
      socket.destroy();
    };

    socket.on("error", (err) => {
      if (!settled) {
        settled = true;
        cleanup();
        reject(err);
      }
    });

    socket.on("close", () => {
      if (!settled) { settled = true; cleanup(); reject(new Error("Action agent disconnected")); }
    });
    socket.on("connect", () => {
      const upgrade = [
        `GET / HTTP/1.1`,
        `Host: localhost`,
        `x-lattices-token: ${token}`,
        `Upgrade: websocket`,
        `Connection: Upgrade`,
        `Sec-WebSocket-Key: ${key}`,
        `Sec-WebSocket-Version: 13`,
        ``,
        ``,
      ].join("\r\n");
      socket.write(upgrade);
    });

    socket.on("data", (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]) as Buffer<ArrayBuffer>;

      if (!upgraded) {
        const headerEnd = buffer.indexOf("\r\n\r\n");
        if (headerEnd === -1) {
          if (buffer.length > 16_384) { settled = true; cleanup(); reject(new Error("Oversized Action handshake")); }
          return;
        }
        const header = buffer.subarray(0, headerEnd).toString();
        const expectedAccept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
        if (!/^HTTP\/1\.[01] 101(?: |$)/.test(header) || !header.split("\r\n").some(line => line.toLowerCase().startsWith("sec-websocket-accept:") && line.slice(line.indexOf(":") + 1).trim() === expectedAccept)) {
          settled = true;
          cleanup();
          reject(new Error("WebSocket upgrade failed"));
          return;
        }
        upgraded = true;
        buffer = buffer.subarray(headerEnd + 4);
        sendFrame(socket, request);
      }

      while (true) {
        let result: ParsedFrame | null;
        try { result = parseFrame(buffer); } catch (error) { settled = true; cleanup(); reject(error); return; }
        if (!result) break;
        buffer = result.rest;

        try {
          const parsed = JSON.parse(result.payload);
          if (parsed.id !== id) continue;
          if (!settled) {
            settled = true;
            cleanup();
            resolve({
              ok: parsed.ok === true,
              result: parsed.result ?? undefined,
              error: parsed.error ?? undefined,
            });
          }
          return;
        } catch {
          if (!settled) {
            settled = true;
            cleanup();
            reject(new Error("Invalid JSON response from Action agent"));
          }
          return;
        }
      }
    });
  });
}

/**
 * Check if the Action agent is reachable.
 */
export async function isActionAgentRunning(timeoutMs = 800): Promise<boolean> {
  try {
    const res = await actionAgentCall("ping", null, timeoutMs);
    return res.ok;
  } catch {
    return false;
  }
}

// MARK: - WebSocket framing helpers

function sendFrame(socket: Socket, text: string): void {
  const payload = Buffer.from(text, "utf8");
  const mask = randomBytes(4);
  const len = payload.length;

  let header: Buffer;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x81;
    header[1] = 0x80 | len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }

  const masked = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i++) {
    masked[i] = payload[i]! ^ mask[i % 4]!;
  }

  socket.write(Buffer.concat([header, mask, masked]));
}

function parseFrame(buf: Buffer): ParsedFrame | null {
  if (buf.length < 2) return null;

  const isMasked = (buf[1]! & 0x80) !== 0;
  let payloadLen = buf[1]! & 0x7f;
  let offset = 2;

  if (payloadLen === 126) {
    if (buf.length < 4) return null;
    payloadLen = buf.readUInt16BE(2);
    offset = 4;
  } else if (payloadLen === 127) {
    if (buf.length < 10) return null;
    payloadLen = Number(buf.readBigUInt64BE(2));
    offset = 10;
  }

  if (!Number.isSafeInteger(payloadLen) || payloadLen > MAX_FRAME_SIZE) throw new Error("Oversized Action response");
  if (isMasked) offset += 4;
  if (buf.length < offset + payloadLen) return null;

  let payload = buf.subarray(offset, offset + payloadLen);
  if (isMasked) {
    const maskKey = buf.subarray(offset - 4, offset);
    payload = Buffer.alloc(payloadLen);
    for (let i = 0; i < payloadLen; i++) {
      payload[i] = buf[offset + i]! ^ maskKey[i % 4]!;
    }
  }

  return {
    payload: payload.toString("utf8"),
    rest: buf.subarray(offset + payloadLen) as Buffer<ArrayBuffer>,
  };
}
