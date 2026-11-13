/**
 * Authenticated WebSocket client for the Action agent's private Unix socket
 * (~/.lattices/run/action.sock, token in action.token). No dependencies.
 *
 * request  { id, method, params: { [key]: string } }
 * response { id, ok, result?: { [key]: string }, error?: string }
 */
import { constants, closeSync, fstatSync, lstatSync, openSync, readFileSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { createHash, randomBytes } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const MAX_FRAME_SIZE = 16 * 1024 * 1024;

export type ActionAgentResult = { ok: boolean; result?: Record<string, string>; error?: string };

export function agentSocketPath(env: Record<string, string | undefined> = process.env): string {
  return env.ACTION_SOCKET_PATH || join(runtimeDirectory(env), "action.sock");
}

function runtimeDirectory(env: Record<string, string | undefined>): string {
  return env.LATTICES_RUNTIME_DIR || join(homedir(), ".lattices", "run");
}

/** The token is a local capability: private, user-owned, never sent anywhere else. */
function readToken(path: string): string {
  const uid = process.getuid?.();
  const directory = lstatSync(dirname(path));
  if (!directory.isDirectory() || (uid !== undefined && directory.uid !== uid) || (directory.mode & 0o077) !== 0) {
    throw new Error("Local IPC directory must be owned by this user with mode 0700");
  }
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = fstatSync(fd);
    if (!info.isFile() || info.nlink !== 1 || (uid !== undefined && info.uid !== uid) || (info.mode & 0o077) !== 0 || info.size > 256) {
      throw new Error("Local IPC token must be a private, user-owned regular file");
    }
    const token = readFileSync(fd, "utf8").trim();
    if (!/^[A-Za-z0-9_+/=-]{32,256}$/.test(token)) throw new Error("Invalid local IPC token");
    return token;
  } finally { closeSync(fd); }
}

function validateSocket(path: string): void {
  const uid = process.getuid?.();
  const directory = lstatSync(dirname(path));
  const info = lstatSync(path);
  if (!directory.isDirectory() || (directory.mode & 0o077) !== 0 || (uid !== undefined && directory.uid !== uid)
    || !info.isSocket() || (info.mode & 0o077) !== 0 || (uid !== undefined && info.uid !== uid)) {
    throw new Error("Local IPC socket must be private and owned by this user");
  }
}

/** Call the Action agent. Param values become strings: the native protocol is [String: String]. */
export async function actionAgentCall(method: string, params?: Record<string, unknown> | null, timeoutMs = 3000): Promise<ActionAgentResult> {
  const env = process.env;
  const socketPath = agentSocketPath(env);
  const token = readToken(join(runtimeDirectory(env), "action.token"));
  validateSocket(socketPath);
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
    const socket = createConnection(socketPath);
    const key = randomBytes(16).toString("base64");
    let settled = false;
    let upgraded = false;
    let buffer: Buffer = Buffer.alloc(0);
    const finish = (error: Error | null, value?: ActionAgentResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(error); else resolve(value!);
    };
    const timer = setTimeout(() => finish(new Error("Action agent request timed out")), timeoutMs);
    socket.on("error", (error) => finish(error));
    socket.on("close", () => finish(new Error("Action agent disconnected")));
    socket.on("connect", () => {
      socket.write([
        "GET / HTTP/1.1", "Host: localhost", `x-lattices-token: ${token}`, "Upgrade: websocket",
        "Connection: Upgrade", `Sec-WebSocket-Key: ${key}`, "Sec-WebSocket-Version: 13", "", "",
      ].join("\r\n"));
    });
    socket.on("data", (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded) {
        const end = buffer.indexOf("\r\n\r\n");
        if (end === -1) {
          if (buffer.length > 16_384) finish(new Error("Oversized Action handshake"));
          return;
        }
        const header = buffer.subarray(0, end).toString();
        const accept = createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
        const accepted = header.split("\r\n").some((line) => line.toLowerCase().startsWith("sec-websocket-accept:") && line.slice(line.indexOf(":") + 1).trim() === accept);
        if (!/^HTTP\/1\.[01] 101(?: |$)/.test(header) || !accepted) return finish(new Error("WebSocket upgrade failed"));
        upgraded = true;
        buffer = buffer.subarray(end + 4);
        sendFrame(socket, request);
      }
      while (true) {
        let frame: { payload: string; rest: Buffer } | null;
        try { frame = parseFrame(buffer); } catch (error) { return finish(error as Error); }
        if (!frame) return;
        buffer = frame.rest;
        let parsed: { id?: string; ok?: boolean; result?: Record<string, string>; error?: string };
        try { parsed = JSON.parse(frame.payload); } catch { return finish(new Error("Invalid JSON response from Action agent")); }
        if (parsed.id !== id) continue;
        return finish(null, { ok: parsed.ok === true, result: parsed.result ?? undefined, error: parsed.error ?? undefined });
      }
    });
  });
}

export async function isActionAgentRunning(timeoutMs = 800): Promise<boolean> {
  try { return (await actionAgentCall("ping", null, timeoutMs)).ok; } catch { return false; }
}

function sendFrame(socket: Socket, text: string): void {
  const payload = Buffer.from(text, "utf8");
  const mask = randomBytes(4);
  const length = payload.length;
  let header: Buffer;
  if (length < 126) {
    header = Buffer.from([0x81, 0x80 | length]);
  } else if (length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81; header[1] = 0x80 | 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81; header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  const masked = Buffer.alloc(length);
  for (let i = 0; i < length; i++) masked[i] = payload[i]! ^ mask[i % 4]!;
  socket.write(Buffer.concat([header, mask, masked]));
}

function parseFrame(buffer: Buffer): { payload: string; rest: Buffer } | null {
  if (buffer.length < 2) return null;
  const masked = (buffer[1]! & 0x80) !== 0;
  let length = buffer[1]! & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2); offset = 4;
  } else if (length === 127) {
    if (buffer.length < 10) return null;
    length = Number(buffer.readBigUInt64BE(2)); offset = 10;
  }
  if (!Number.isSafeInteger(length) || length > MAX_FRAME_SIZE) throw new Error("Oversized Action response");
  if (masked) offset += 4;
  if (buffer.length < offset + length) return null;
  let payload = buffer.subarray(offset, offset + length);
  if (masked) {
    const maskKey = buffer.subarray(offset - 4, offset);
    payload = Buffer.from(payload.map((byte, i) => byte ^ maskKey[i % 4]!));
  }
  return { payload: payload.toString("utf8"), rest: buffer.subarray(offset + length) };
}
