// Lightweight WebSocket client for lattices daemon (ws://127.0.0.1:9399)
// Uses Node `net` module with manual HTTP upgrade + minimal WS framing.
// Zero npm dependencies.

import { createConnection, type Socket } from "node:net";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pairingHeaders } from "./host-pairing.ts";

const DEFAULT_DAEMON_HOST = "127.0.0.1";
const DEFAULT_DAEMON_PORT = 9399;

/**
 * Where daemon calls go. Defaults to the local Mac daemon; set
 * LATTICES_DAEMON_HOST (or pass `lats --host <name>`) to reach another
 * lattices host, such as a Linux machine running lattices-host on the tailnet
 * (LAT-013). Read per call so the CLI's --host flag can set it at startup.
 */
export function daemonEndpoint(
  env: Record<string, string | undefined> = process.env
): { host: string; port: number } {
  const host = env.LATTICES_DAEMON_HOST?.trim() || DEFAULT_DAEMON_HOST;
  const port = Number(env.LATTICES_DAEMON_PORT);
  return { host, port: Number.isInteger(port) && port > 0 ? port : DEFAULT_DAEMON_PORT };
}

// The Voice helper (bundle dev.lattices.Speech) writes this capability when it
// runs. The daemon forwards voice output verbs only for clients that present it.
const VOICE_CAPABILITY_FILE = join(
  homedir(),
  "Library/Application Support/Speech/RPC/capability"
);
const VOICE_TOKEN_HEADER = "x-lattices-speech-token";

function voiceTokenHeader(method: string): string[] {
  if (!method.startsWith("voice.") && !method.startsWith("speech.")) return [];
  try {
    const token = readFileSync(VOICE_CAPABILITY_FILE, "utf8").trim();
    return token && !/[\r\n]/.test(token) ? [`${VOICE_TOKEN_HEADER}: ${token}`] : [];
  } catch {
    return [];
  }
}

// Who is calling. The daemon logs and shows agent screenshots, so it needs to
// know which agent asked and from where. Header values stay ASCII, one line.
const CALLER_HEADER = "x-lattices-caller";

function detectAgent(env: NodeJS.ProcessEnv): string {
  if (env.LATTICES_AGENT) return env.LATTICES_AGENT;
  if (env.CLAUDECODE || env.CLAUDE_CODE_ENTRYPOINT) return "claude";
  if (Object.keys(env).some((k) => k.startsWith("CODEX_"))) return "codex";
  if (env.OPENCODE || env.OPENCODE_BIN_PATH) return "opencode";
  if (env.CURSOR_AGENT || env.CURSOR_TRACE_ID) return "cursor";
  return "";
}

function callerHeader(): string[] {
  const env = process.env;
  const ssh = (env.SSH_CONNECTION || env.SSH_CLIENT || "").split(" ")[0];
  const caller = {
    agent: detectAgent(env),
    client: env.LATTICES_CLIENT || "cli",
    origin: ssh ? `ssh ${ssh}` : "local",
    cwd: process.cwd(),
    pid: process.pid,
  };
  const value = Buffer.from(JSON.stringify(caller)).toString("base64");
  return [`${CALLER_HEADER}: ${value}`];
}

interface ParsedFrame {
  payload: string;
  rest: Buffer<ArrayBuffer>;
}

// LAT-012 renamed the daemon's methods into domains (window.place ->
// windows.place). The daemon still accepts the old names, but a daemon from
// before the rename does not know the new ones, so an `Unknown method` answer
// for a new name is retried once under its old name.
const LEGACY_METHOD_NAMES: Record<string, string> = {
  "windows.focus": "window.focus",
  "windows.move": "window.move",
  "windows.place": "window.place",
  "windows.present": "window.present",
  "windows.resolve": "window.resolve",
  "windows.pick": "window.pick.start",
  "layers.activate": "layer.activate",
  "layers.switch": "layer.switch",
  "spaces.optimize": "space.optimize",
  "sessions.launch": "session.launch",
  "sessions.kill": "session.kill",
  "sessions.detach": "session.detach",
  "sessions.sync": "session.sync",
  "sessions.restart": "session.restart",
  "groups.launch": "group.launch",
  "groups.kill": "group.kill",
  "tabs.list": "tabStacks.list",
  "tabs.stack": "tabStacks.create",
  "tabs.add": "tabStacks.add",
  "tabs.select": "tabStacks.select",
  "tabs.layout": "tabStacks.layout",
  "tabs.unstack": "tabStacks.delete",
  "search.query": "lattices.search",
  "solo.status": "focus.status",
  "solo.enter": "focus.enter",
  "solo.exit": "focus.exit",
  "solo.toggle": "focus.toggle",
  "intents.run": "intents.execute",
  "history.list": "actions.history",
  "history.undo": "actions.undo",
};

/** The pre-LAT-012 name to retry `method` under, or undefined. */
export function legacyMethodName(
  method: string,
  params?: Record<string, unknown> | null
): string | undefined {
  if (method === "tmux.list") return params?.includeOrphans === true ? "tmux.inventory" : "tmux.sessions";
  if (method === "ocr.history") return params?.wid == null ? "ocr.recent" : undefined;
  return LEGACY_METHOD_NAMES[method];
}

/**
 * Send a JSON-RPC-style request to the daemon and return the response.
 */
export async function daemonCall(
  method: string,
  params?: Record<string, unknown> | null,
  timeoutMs = 3000
): Promise<unknown> {
  return daemonCallTo(daemonEndpoint(), method, params, timeoutMs);
}

/** `daemonCall` against an explicit host, for clients that address several (LAT-013). */
export async function daemonCallTo(
  endpoint: { host: string; port: number },
  method: string,
  params?: Record<string, unknown> | null,
  timeoutMs = 3000
): Promise<unknown> {
  try {
    return await sendRequest(endpoint, method, params, timeoutMs);
  } catch (err) {
    const legacy = legacyMethodName(method, params);
    if (!legacy || (err as Error).message !== `Unknown method: ${method}`) throw err;
    return sendRequest(endpoint, legacy, params, timeoutMs);
  }
}

async function sendRequest(
  endpoint: { host: string; port: number },
  method: string,
  params: Record<string, unknown> | null | undefined,
  timeoutMs: number
): Promise<unknown> {
  const id = randomBytes(4).toString("hex");
  const deadline = Date.now() + timeoutMs;
  const request = JSON.stringify({ id, method, params: params ?? null, deadline });
  const mutation = method.startsWith("computer.") && !/\.(observe|capture|status)$/.test(method);
  const uncertain = () => new Error("Daemon connection lost or deadline exceeded; action outcome uncertain; do not retry blindly");

  return new Promise((resolve, reject) => {
    const { host, port } = endpoint;
    const socket = createConnection({ host, port });
    let settled = false;
    let buffer = Buffer.alloc(0);
    let upgraded = false;
    let sent = false;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        socket.destroy();
        reject(mutation && sent ? uncertain() : new Error("Daemon request timed out"));
      }
    }, timeoutMs + (mutation ? 1500 : 0));

    const cleanup = () => {
      clearTimeout(timer);
      socket.destroy();
    };

    socket.on("error", (err) => {
      if (!settled) {
        settled = true;
        cleanup();
        reject(mutation && sent ? uncertain() : err);
      }
    });

    socket.on("close", () => {
      if (!settled) {
        settled = true;
        cleanup();
        reject(mutation && sent ? uncertain() : new Error("Daemon connection closed"));
      }
    });
    socket.on("connect", () => {
      // Send HTTP upgrade request
      const key = randomBytes(16).toString("base64");
      const upgrade = [
        `GET / HTTP/1.1`,
        `Host: ${host}:${port}`,
        `Upgrade: websocket`,
        `Connection: Upgrade`,
        `Sec-WebSocket-Key: ${key}`,
        `Sec-WebSocket-Version: 13`,
        ...voiceTokenHeader(method),
        ...callerHeader(),
        // A paired remote host needs every connection signed (LAT-013). A
        // pairing request goes unsigned so a host that forgot us can re-pair.
        ...(method === "clients.pair" ? [] : pairingHeaders(endpoint)),
        ``,
        ``,
      ].join("\r\n");
      socket.write(upgrade);
    });

    socket.on("data", (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]) as Buffer<ArrayBuffer>;

      if (!upgraded) {
        const headerEnd = buffer.indexOf("\r\n\r\n");
        if (headerEnd === -1) return;
        const header = buffer.subarray(0, headerEnd).toString();
        if (!header.includes("101")) {
          settled = true;
          cleanup();
          // lattices-host explains a 401/403 in the body (unpaired, revoked, bad signature).
          const status = header.split("\r\n")[0]!.split(" ")[1];
          const reason = (status === "401" || status === "403") ? buffer.subarray(headerEnd + 4).toString().trim() : "";
          reject(new Error(reason ? `WebSocket upgrade failed (${status}): ${reason}` : "WebSocket upgrade failed"));
          return;
        }
        upgraded = true;
        buffer = buffer.subarray(headerEnd + 4);

        // Send the request as a masked WebSocket text frame
        sent = true;
        sendFrame(socket, request);
      }

      // The daemon can push broadcast events before the RPC response.
      // Keep consuming frames until we see our matching response id.
      while (true) {
        const result = parseFrame(buffer);
        if (!result) break;
        buffer = result.rest;

        try {
          const parsed = JSON.parse(result.payload);
          if (parsed.event) {
            continue;
          }
          if (parsed.id !== id) {
            continue;
          }
          if (!settled) {
            settled = true;
            cleanup();
            if (parsed.error) {
              reject(new Error(parsed.error));
            } else {
              resolve(parsed.result);
            }
          }
          return;
        } catch {
          if (!settled) {
            settled = true;
            cleanup();
            reject(mutation && sent ? uncertain() : new Error("Invalid JSON response from daemon"));
          }
          return;
        }
      }
    });
  });
}

/**
 * Check if the daemon is reachable.
 */
export async function isDaemonRunning(): Promise<boolean> {
  try {
    await daemonCall("daemon.status", null, 1000);
    return true;
  } catch (err) {
    // A lattices-host that answers but refuses this client (unpaired, revoked)
    // is running; the caller's own request will surface why.
    return /^(pairing_required|scope_denied|loopback_only)|upgrade failed \((401|403)\)/.test((err as Error).message);
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
    header[0] = 0x81; // FIN + text opcode
    header[1] = 0x80 | len; // masked + length
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

  // Mask payload
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
