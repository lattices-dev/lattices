// Lightweight authenticated client: private Unix socket locally, explicit remote gateway.
// Uses Node `net` module with manual HTTP upgrade + minimal WS framing.
// Zero npm dependencies.

import { createConnection, type Socket } from "node:net";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pairingHeaders } from "./host-pairing.ts";
import { localEndpoint, readLocalToken, validateLocalSocket, type DaemonEndpoint } from "./local-ipc.ts";
export type { DaemonEndpoint } from "./local-ipc.ts";

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
): DaemonEndpoint {
  if (!env.LATTICES_DAEMON_HOST && !env.LATTICES_DAEMON_PORT && env.LATTICES_ALLOW_LOOPBACK_TCP !== "1") return localEndpoint("lattices", env);
  const host = env.LATTICES_DAEMON_HOST?.trim() || DEFAULT_DAEMON_HOST;
  const port = Number(env.LATTICES_DAEMON_PORT);
  return { host, port: Number.isInteger(port) && port > 0 ? port : DEFAULT_DAEMON_PORT,
    // A loopback address can be an SSH tunnel. Only the separate compatibility
    // opt-in permits sending this machine's capability over local TCP.
    ...(env.LATTICES_ALLOW_LOOPBACK_TCP === "1" && ["127.0.0.1", "localhost", "::1"].includes(host)
      ? { tokenFile: localEndpoint("lattices", env).tokenFile } : {}) };
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
  payload: Buffer;
  opcode: number;
  final: boolean;
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
  endpoint: DaemonEndpoint,
  method: string,
  params?: Record<string, unknown> | null,
  timeoutMs = 3000,
  signal?: AbortSignal
): Promise<unknown> {
  try {
    return await sendRequest(endpoint, method, params, timeoutMs, signal);
  } catch (err) {
    const legacy = legacyMethodName(method, params);
    if (signal?.aborted || !legacy || (err as Error).message !== `Unknown method: ${method}`) throw err;
    return sendRequest(endpoint, legacy, params, timeoutMs, signal);
  }
}

async function sendRequest(
  endpoint: DaemonEndpoint,
  method: string,
  params: Record<string, unknown> | null | undefined,
  timeoutMs: number,
  signal?: AbortSignal
): Promise<unknown> {
  signal?.throwIfAborted();
  if (endpoint.socketPath) validateLocalSocket(endpoint.socketPath);
  // A programmatic caller may explicitly provide tokenFile for local TCP
  // compatibility. Reject remote use before reading any local credential.
  if (endpoint.tokenFile && !endpoint.socketPath && !["127.0.0.1", "localhost", "::1"].includes(endpoint.host)) throw new Error("Refusing to send a local capability to a remote host");
  const localToken = endpoint.tokenFile ? readLocalToken(endpoint.tokenFile) : undefined;
  const id = randomBytes(4).toString("hex");
  const deadline = Date.now() + timeoutMs;
  const request = JSON.stringify({ id, method, params: params ?? null, deadline });
  const mutation = method.startsWith("computer.") && !/\.(observe|capture|status)$/.test(method);
  const uncertain = () => new Error("Daemon connection lost or deadline exceeded; action outcome uncertain; do not retry blindly");

  return new Promise((resolve, reject) => {
    const { host, port } = endpoint;
    const socket = createConnection(endpoint.socketPath ? { path: endpoint.socketPath } : { host, port });
    let settled = false;
    let buffer = Buffer.alloc(0);
    let upgraded = false;
    let sent = false;
    let expectedAccept = "";
    let fragments: Buffer[] | null = null;
    let fragmentBytes = 0;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        cleanup();
        reject(mutation && sent ? uncertain() : new Error("Daemon request timed out"));
      }
    }, timeoutMs + (mutation ? 1500 : 0));

    const cleanup = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", aborted);
      socket.destroy();
    };

    const aborted = () => {
      if (settled) return;
      settled = true; cleanup(); reject(signal?.reason ?? new Error("Daemon call cancelled"));
    };
    signal?.addEventListener("abort", aborted, { once: true });
    if (signal?.aborted) aborted();

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
      if (settled) return;
      // Send HTTP upgrade request
      const key = randomBytes(16).toString("base64");
      expectedAccept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      const upgrade = [
        `GET / HTTP/1.1`,
        `Host: ${endpoint.socketPath ? "localhost" : `${host}:${port}`}`,
        `Upgrade: websocket`,
        `Connection: Upgrade`,
        `Sec-WebSocket-Key: ${key}`,
        `Sec-WebSocket-Version: 13`,
        ...(endpoint.socketPath || localToken ? voiceTokenHeader(method) : []),
        ...(localToken ? [`x-lattices-token: ${localToken}`] : []),
        ...callerHeader(),
        // A paired remote host needs every connection signed (LAT-013). A
        // pairing request goes unsigned so a host that forgot us can re-pair.
        ...(endpoint.socketPath || method === "clients.pair" ? [] : pairingHeaders(endpoint)),
        ``,
        ``,
      ].join("\r\n");
      socket.write(upgrade);
    });

    socket.on("data", (chunk: Buffer) => {
      if (settled) return;
      if (buffer.length + chunk.length > 64 * 1024 * 1024) {
        settled = true; cleanup(); reject(new Error("Daemon response exceeds size limit")); return;
      }
      buffer = Buffer.concat([buffer, chunk]) as Buffer<ArrayBuffer>;

      if (!upgraded) {
        const headerEnd = buffer.indexOf("\r\n\r\n");
        if (headerEnd === -1 || headerEnd > 8192) {
          if (buffer.length > 8192) { settled = true; cleanup(); reject(new Error("Daemon upgrade exceeds size limit")); }
          return;
        }
        const header = buffer.subarray(0, headerEnd).toString();
        if (!/^HTTP\/1\.[01] 101(?: |$)/.test(header)) {
          settled = true;
          cleanup();
          // lattices-host explains a 401/403 in the body (unpaired, revoked, bad signature).
          const status = header.split("\r\n")[0]!.split(" ")[1];
          const reason = (status === "401" || status === "403") ? buffer.subarray(headerEnd + 4).toString().trim() : "";
          reject(new Error(reason ? `WebSocket upgrade failed (${status}): ${reason}` : "WebSocket upgrade failed"));
          return;
        }
        const accept = header.split("\r\n").filter(line => /^sec-websocket-accept:/i.test(line));
        if (accept.length !== 1 || accept[0]!.split(":").slice(1).join(":").trim() !== expectedAccept) {
          settled = true; cleanup(); reject(new Error("Invalid WebSocket upgrade response")); return;
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
        let result: ParsedFrame | null;
        try { result = parseFrame(buffer); } catch (error) { settled = true; cleanup(); reject(error); return; }
        if (!result) break;
        buffer = result.rest;

        try {
          if (result.opcode === 8) throw new Error("Daemon connection closed");
          if (result.opcode === 9) { sendFrame(socket, result.payload, 10); continue; }
          if (result.opcode === 10) continue;
          if (result.opcode === 2) throw new Error("Unexpected binary daemon response");
          if (result.opcode === 0) {
            if (!fragments) throw new Error("Unexpected continuation frame");
          } else {
            if (fragments) throw new Error("Interrupted fragmented daemon response");
            fragments = []; fragmentBytes = 0;
          }
          fragmentBytes += result.payload.length;
          if (fragmentBytes > 64 * 1024 * 1024) throw new Error("Daemon response exceeds size limit");
          fragments.push(result.payload);
          if (!result.final) continue;
          const payload = Buffer.concat(fragments, fragmentBytes);
          fragments = null; fragmentBytes = 0;
          const parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(payload));
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
              reject(new Error(typeof parsed.error === "string" ? parsed.error : parsed.error.message ?? "Daemon request failed"));
            } else {
              resolve(parsed.result);
            }
          }
          return;
        } catch (error) {
          if (!settled) {
            settled = true;
            cleanup();
            reject(mutation && sent ? uncertain() : error instanceof SyntaxError || error instanceof TypeError ? new Error("Invalid JSON response from daemon") : error);
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

function sendFrame(socket: Socket, text: string | Buffer, opcode = 1): void {
  const payload = typeof text === "string" ? Buffer.from(text, "utf8") : text;
  const mask = randomBytes(4);
  const len = payload.length;

  let header: Buffer;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x80 | opcode; // FIN + opcode
    header[1] = 0x80 | len; // masked + length
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
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

  const opcode = buf[0]! & 15;
  const final = (buf[0]! & 0x80) !== 0;
  if ((buf[0]! & 0x70) || (buf[1]! & 0x80) || ![0, 1, 2, 8, 9, 10].includes(opcode)) throw new Error("Invalid daemon frame");
  if (opcode >= 8 && (!final || (buf[1]! & 127) > 125)) throw new Error("Invalid daemon control frame");
  let payloadLen = buf[1]! & 0x7f;
  let offset = 2;

  if (payloadLen === 126) {
    if (buf.length < 4) return null;
    payloadLen = buf.readUInt16BE(2);
    offset = 4;
  } else if (payloadLen === 127) {
    if (buf.length < 10) return null;
    const wideLength = buf.readBigUInt64BE(2);
    if (wideLength > 64n * 1024n * 1024n) throw new Error("Daemon frame exceeds size limit");
    payloadLen = Number(wideLength);
    offset = 10;
  }

  if (buf.length < offset + payloadLen) return null;
  return {
    payload: buf.subarray(offset, offset + payloadLen), opcode, final,
    rest: buf.subarray(offset + payloadLen) as Buffer<ArrayBuffer>,
  };
}
