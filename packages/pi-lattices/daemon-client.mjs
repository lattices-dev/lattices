import { createHash, randomBytes } from "node:crypto";
import { createConnection } from "node:net";
import { constants, closeSync, fstatSync, lstatSync, openSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const DEFAULT_DAEMON_HOST = "127.0.0.1";
const DEFAULT_DAEMON_PORT = 9399;
const DEFAULT_TIMEOUT_MS = 3000;

export function daemonConfig(overrides = {}) {
  const host = overrides.host ?? process.env.LATTICES_DAEMON_HOST ?? DEFAULT_DAEMON_HOST;
  const rawPort = overrides.port ?? process.env.LATTICES_DAEMON_PORT ?? DEFAULT_DAEMON_PORT;
  const rawTimeout = overrides.timeoutMs ?? process.env.LATTICES_DAEMON_TIMEOUT_MS ?? DEFAULT_TIMEOUT_MS;
  const port = Number(rawPort);
  const timeoutMs = Number(rawTimeout);
  const directory = process.env.LATTICES_RUNTIME_DIR || join(homedir(), ".lattices", "run");
  const tokenFile = join(directory, "lattices.token");
  const explicitNetwork = overrides.host !== undefined || overrides.port !== undefined
    || !!process.env.LATTICES_DAEMON_HOST || !!process.env.LATTICES_DAEMON_PORT;
  const compatibility = process.env.LATTICES_ALLOW_LOOPBACK_TCP === "1";
  if (!explicitNetwork && !compatibility) return {
    host: "localhost", port: 0, socketPath: join(directory, "lattices.sock"), tokenFile,
    timeoutMs: Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : DEFAULT_TIMEOUT_MS,
  };
  if (typeof host !== "string" || /[\r\n]/.test(host)) throw new Error("Invalid daemon host");

  return {
    host,
    port: Number.isFinite(port) && port > 0 ? port : DEFAULT_DAEMON_PORT,
    timeoutMs: Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : DEFAULT_TIMEOUT_MS,
    // Explicit remote endpoints, including local tunnels, never receive a
    // local capability. Loopback compatibility needs a separate opt-in.
    ...(compatibility && ["127.0.0.1", "localhost", "::1"].includes(host) ? { tokenFile } : {}),
  };
}

// Standalone Node 18 package: match desktop-client/local-ipc.ts without a
// dependency on repository TypeScript sources.
function privateToken(tokenFile, socketPath) {
  const uid = process.getuid?.(), dir = lstatSync(dirname(tokenFile));
  if (!dir.isDirectory() || (dir.mode & 0o077) !== 0 || (uid !== undefined && dir.uid !== uid)) {
    throw new Error("Local IPC directory must be owned by this user with mode 0700");
  }
  if (socketPath) {
    const socket = lstatSync(socketPath);
    if (!socket.isSocket() || (socket.mode & 0o077) !== 0 || (uid !== undefined && socket.uid !== uid)) {
      throw new Error("Local IPC socket must be private and owned by this user");
    }
  }
  const fd = openSync(tokenFile, constants.O_RDONLY | constants.O_NOFOLLOW);
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

// Daemons from before LAT-012 only know the old method names.
const LEGACY_METHOD_NAMES = {
  "windows.place": "window.place",
};

export async function daemonCall(method, params = null, options = {}) {
  try {
    return await sendRequest(method, params, options);
  } catch (error) {
    const legacy = LEGACY_METHOD_NAMES[method];
    if (!legacy || error?.message !== `Unknown method: ${method}`) throw error;
    return sendRequest(legacy, params, options);
  }
}

function sendRequest(method, params, options) {
  const { host, port, timeoutMs, socketPath, tokenFile } = daemonConfig(options);
  const token = tokenFile ? privateToken(tokenFile, socketPath) : undefined;
  const id = randomBytes(4).toString("hex");
  const request = JSON.stringify({ id, method, params: params ?? null });

  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath ? { path: socketPath } : { host, port });
    let settled = false;
    let upgraded = false;
    let buffer = Buffer.alloc(0);
    let expectedAccept = "";

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        socket.destroy();
        const error = new Error(`Daemon request timed out after ${timeoutMs}ms`);
        error.code = "LATTICES_DAEMON_TIMEOUT";
        reject(error);
      }
    }, timeoutMs);

    const cleanup = () => {
      clearTimeout(timer);
      socket.destroy();
    };

    socket.on("error", (error) => {
      if (!settled) {
        settled = true;
        cleanup();
        reject(error);
      }
    });

    socket.on("connect", () => {
      const key = randomBytes(16).toString("base64");
      expectedAccept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      const upgrade = [
        "GET / HTTP/1.1",
        `Host: ${socketPath ? "localhost" : `${host}:${port}`}`,
        ...(token ? [`x-lattices-token: ${token}`] : []),
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        "",
        "",
      ].join("\r\n");
      socket.write(upgrade);
    });

    socket.on("close", () => {
      if (!settled) { settled = true; cleanup(); reject(new Error("Daemon connection closed")); }
    });

    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);

      if (!upgraded) {
        const headerEnd = buffer.indexOf("\r\n\r\n");
        if (headerEnd === -1) {
          if (buffer.length > 16_384) { settled = true; cleanup(); reject(new Error("Oversized WebSocket upgrade response")); }
          return;
        }

        const header = buffer.subarray(0, headerEnd).toString();
        const accepts = header.split("\r\n").filter(line => /^sec-websocket-accept:/i.test(line));
        if (headerEnd > 16_384 || !/^HTTP\/1\.[01] 101(?: |$)/.test(header) || accepts.length !== 1 || accepts[0].slice(accepts[0].indexOf(":") + 1).trim() !== expectedAccept) {
          settled = true;
          cleanup();
          const error = new Error("WebSocket upgrade failed");
          error.code = "LATTICES_DAEMON_UPGRADE";
          reject(error);
          return;
        }

        upgraded = true;
        buffer = buffer.subarray(headerEnd + 4);
        sendFrame(socket, request);
      }

      while (true) {
        let parsedFrame;
        try { parsedFrame = parseFrame(buffer); }
        catch (error) { settled = true; cleanup(); reject(error); return; }
        if (!parsedFrame) break;
        buffer = parsedFrame.rest;

        try {
          const parsed = JSON.parse(parsedFrame.payload);
          if (parsed.event || parsed.id !== id) continue;

          if (!settled) {
            settled = true;
            cleanup();
            if (parsed.error) {
              const error = new Error(parsed.error);
              error.code = "LATTICES_DAEMON_ERROR";
              reject(error);
            } else {
              resolve(parsed.result);
            }
          }
          return;
        } catch {
          if (!settled) {
            settled = true;
            cleanup();
            const error = new Error("Invalid JSON response from Lattices daemon");
            error.code = "LATTICES_DAEMON_INVALID_JSON";
            reject(error);
          }
          return;
        }
      }
    });
  });
}

export function isDaemonUnavailable(error) {
  const code = error?.code;
  return code === "ECONNREFUSED"
    || code === "ENOENT"
    || code === "ECONNRESET"
    || code === "EHOSTUNREACH"
    || code === "ENETUNREACH"
    || code === "ETIMEDOUT"
    || code === "LATTICES_DAEMON_TIMEOUT"
    || code === "LATTICES_DAEMON_UPGRADE";
}

function sendFrame(socket, text) {
  const payload = Buffer.from(text, "utf8");
  const mask = randomBytes(4);
  const len = payload.length;

  let header;
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
  for (let i = 0; i < payload.length; i += 1) {
    masked[i] = payload[i] ^ mask[i % 4];
  }

  socket.write(Buffer.concat([header, mask, masked]));
}

function parseFrame(buf) {
  if (buf.length < 2) return null;

  const isMasked = (buf[1] & 0x80) !== 0;
  let payloadLen = buf[1] & 0x7f;
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

  if (!Number.isSafeInteger(payloadLen) || payloadLen > 16 * 1024 * 1024) throw new Error("WebSocket frame exceeds limit");

  if (isMasked) offset += 4;
  if (buf.length < offset + payloadLen) return null;

  let payload = buf.subarray(offset, offset + payloadLen);
  if (isMasked) {
    const maskKey = buf.subarray(offset - 4, offset);
    payload = Buffer.alloc(payloadLen);
    for (let i = 0; i < payloadLen; i += 1) {
      payload[i] = buf[offset + i] ^ maskKey[i % 4];
    }
  }

  return {
    payload: payload.toString("utf8"),
    rest: buf.subarray(offset + payloadLen),
  };
}
