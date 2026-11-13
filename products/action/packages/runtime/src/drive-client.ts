import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import WebSocket from "ws";
import { actionSocketPath, actionTokenPath, readPrivateToken } from "./local-security.js";

import type {
  AxActionTier,
  DriveLease,
  DriveMode,
  DriveOutcome,
  DriveStatusSnapshot,
} from "@action/protocol";

interface ActionAgentResponse {
  id: string;
  ok: boolean;
  result?: Record<string, string>;
  error?: string;
}

interface PendingRequest {
  resolve: (result: Record<string, string>) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
}

export interface DriveAgentClientOptions {
  launcherPath: string;
  host?: string;
  port?: number;
  requestTimeoutMs?: number;
  startupTimeoutMs?: number;
  /** How this client names itself on the leases it begins, e.g. "Action MCP". */
  clientName?: string;
}

export interface DriveBeginInput {
  agent: string;
  task: string;
  mode?: DriveMode;
  /** The folder the driving harness works in, e.g. "talkie". */
  project?: string;
  sessionId?: string;
  implicit?: boolean;
  showSupervisionLabel?: boolean;
  /** Opt in to attention-tier control (pointer drags, coordinate targeting). */
  pointerControl?: boolean;
}

export interface DriveBeginResult {
  status: "granted" | "denied";
  lease: DriveLease;
  reason?: string;
}

/**
 * Persistent client for the native Action agent.
 *
 * The socket is deliberately kept open for the MCP process lifetime. The
 * native runtime associates leases with this connection and cancels them when
 * the client disappears, so a crashed harness cannot leave the Mac "driving".
 */
export class DriveAgentClient {
  private readonly launcherPath: string;
  private readonly host: string;
  private readonly port: number;
  private readonly requestTimeoutMs: number;
  private readonly startupTimeoutMs: number;
  private readonly clientName?: string;
  private socket?: WebSocket;
  private connectPromise?: Promise<WebSocket>;
  private readonly pending = new Map<string, PendingRequest>();

  constructor(options: DriveAgentClientOptions) {
    this.launcherPath = options.launcherPath;
    this.host = options.host ?? "127.0.0.1";
    this.port = options.port ?? 4319;
    this.requestTimeoutMs = options.requestTimeoutMs ?? 20_000;
    this.startupTimeoutMs = options.startupTimeoutMs ?? 120_000;
    this.clientName = options.clientName;
  }

  get isConnected(): boolean {
    return this.socket?.readyState === WebSocket.OPEN;
  }

  async begin(input: DriveBeginInput): Promise<DriveBeginResult> {
    const result = await this.request("drive.begin", {
      agent: input.agent,
      task: input.task,
      mode: input.mode ?? "background",
      sessionId: input.sessionId,
      implicit: input.implicit === true ? "true" : undefined,
      showSupervisionLabel: input.showSupervisionLabel === false ? "false" : "true",
      pointerControl: input.pointerControl === true ? "true" : "false",
      client: this.clientName,
      project: input.project,
    });
    return {
      status: result.status === "denied" ? "denied" : "granted",
      lease: parseAgentJSON<DriveLease>(result, "lease"),
      reason: result.reason,
    };
  }

  async touch(input: {
    leaseId?: string;
    axTier?: AxActionTier;
    actionKind?: string;
  } = {}): Promise<DriveLease | undefined> {
    let result: Record<string, string>;
    try {
      result = await this.request("drive.touch", {
        leaseId: input.leaseId,
        axTier: input.axTier,
        actionKind: input.actionKind,
      });
    } catch (error) {
      if (isDriveLeaseInactiveError(error)) {
        return undefined;
      }
      throw error;
    }
    if (result.status === "idle") {
      return undefined;
    }
    return parseAgentJSON<DriveLease>(result, "lease");
  }

  async release(input: {
    leaseId: string;
    outcome?: DriveOutcome;
    summary?: string;
  }): Promise<DriveLease> {
    const result = await this.request("drive.release", input);
    return parseAgentJSON<DriveLease>(result, "lease");
  }

  async status(): Promise<DriveStatusSnapshot> {
    const result = await this.request("drive.status");
    return parseAgentJSON<DriveStatusSnapshot>(result, "snapshot");
  }

  close(): void {
    this.socket?.close(1000, "Action MCP closed");
    this.socket = undefined;
    this.rejectPending(new Error("Action agent connection closed"));
  }

  private async request(
    method: string,
    params: Record<string, string | undefined> = {},
  ): Promise<Record<string, string>> {
    const socket = await this.ensureConnected();
    const id = randomUUID();
    const cleanParams = Object.fromEntries(
      Object.entries({ ...params, authToken: readPrivateToken(actionTokenPath()), protocolVersion: "2" }).filter((entry): entry is [string, string] => entry[1] !== undefined),
    );

    return new Promise<Record<string, string>>((resolvePromise, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Action agent request timed out: ${method}`));
        this.dropIfUnresponsive(socket);
      }, this.requestTimeoutMs);
      this.pending.set(id, { resolve: resolvePromise, reject, timeout });

      try {
        socket.send(JSON.stringify({ id, method, params: cleanParams }));
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  private async ensureConnected(): Promise<WebSocket> {
    if (this.socket?.readyState === WebSocket.OPEN) {
      return this.socket;
    }
    if (!this.connectPromise) {
      this.connectPromise = this.connectWithStartup().finally(() => {
        this.connectPromise = undefined;
      });
    }
    return this.connectPromise;
  }

  private async connectWithStartup(): Promise<WebSocket> {
    try {
      return await this.connectOnce(400);
    } catch {
      // Fall through: nothing answered, so start or replace the agent.
    }

    // An agent that holds the socket lock but won't answer keeps every new agent
    // out. Give it a moment in case it is busy, then replace it.
    const owner = readAgentOwner();
    if (owner && owner.ageSeconds >= STUCK_OWNER_MIN_AGE_SECONDS) {
      try {
        return await this.retryConnect(Date.now() + STUCK_OWNER_GRACE_MS);
      } catch {
        await reapAgent(owner.pid);
      }
    }

    const child = await this.launchAgent();
    return this.retryConnect(Date.now() + this.startupTimeoutMs, child);
  }

  private async retryConnect(deadline: number, child?: ChildProcess): Promise<WebSocket> {
    let lastError: unknown;
    let backoff = CONNECT_BACKOFF_MIN_MS;
    while (Date.now() < deadline) {
      try {
        return await this.connectOnce(500);
      } catch (error) {
        lastError = error;
      }
      // The agent we started exited: waiting out the startup timeout won't help.
      if (child && child.exitCode !== null && child.exitCode !== 0) {
        const owner = readAgentOwner();
        throw new Error(owner && owner.pid !== child.pid
          ? `Action agent pid ${owner.pid} holds the socket but is not answering`
          : `Action agent exited with code ${child.exitCode} during startup`);
      }
      await delay(Math.min(backoff, Math.max(0, deadline - Date.now())));
      backoff = Math.min(backoff * 2, CONNECT_BACKOFF_MAX_MS);
    }
    throw new Error(`Action agent did not answer within ${this.startupTimeoutMs}ms: ${String(lastError)}`);
  }

  /** After a request timeout, drop the socket if the agent no longer answers pings. */
  private dropIfUnresponsive(socket: WebSocket): void {
    if (socket.readyState !== WebSocket.OPEN) return;
    const timer = setTimeout(() => {
      if (this.socket === socket) this.socket = undefined;
      socket.terminate();
    }, PING_TIMEOUT_MS);
    timer.unref?.();
    socket.once("pong", () => clearTimeout(timer));
    try {
      socket.ping();
    } catch {
      clearTimeout(timer);
      socket.terminate();
    }
  }

  private connectOnce(timeoutMs: number): Promise<WebSocket> {
    return new Promise<WebSocket>((resolvePromise, reject) => {
      const token = readPrivateToken(actionTokenPath());
      const tcp = process.env.ACTION_ALLOW_TCP === "1";
      if (tcp && !["127.0.0.1", "localhost", "::1"].includes(this.host)) throw new Error("Action compatibility TCP must use loopback; use the host gateway for remote access");
      const socket = new WebSocket(tcp ? `ws://${this.host}:${this.port}` : `ws+unix://${actionSocketPath()}:/`, {
        headers: { "x-lattices-token": token, ...(tcp ? {} : { Host: "localhost" }) },
        maxPayload: 16 * 1024 * 1024,
        handshakeTimeout: timeoutMs,
      });
      const timeout = setTimeout(() => {
        socket.close();
        reject(new Error("Action agent connection timed out"));
      }, timeoutMs);

      const onOpen = () => {
        clearTimeout(timeout);
        socket.removeEventListener("error", onError);
        this.installSocket(socket);
        resolvePromise(socket);
      };
      const onError = () => {
        clearTimeout(timeout);
        socket.removeEventListener("open", onOpen);
        reject(new Error("Action agent is unavailable"));
      };

      socket.addEventListener("open", onOpen, { once: true });
      socket.addEventListener("error", onError, { once: true });
    });
  }

  private installSocket(socket: WebSocket): void {
    this.socket = socket;
    socket.addEventListener("message", (event) => {
      let raw: string;
      if (typeof event.data === "string") {
        raw = event.data;
      } else if (event.data instanceof ArrayBuffer) {
        raw = new TextDecoder().decode(event.data);
      } else {
        raw = String(event.data);
      }

      let response: ActionAgentResponse;
      try {
        response = JSON.parse(raw) as ActionAgentResponse;
      } catch {
        return;
      }
      const pending = this.pending.get(response.id);
      if (!pending) {
        return;
      }
      clearTimeout(pending.timeout);
      this.pending.delete(response.id);
      if (!response.ok) {
        pending.reject(new Error(response.error ?? "Action agent request failed"));
        return;
      }
      pending.resolve(response.result ?? {});
    });
    socket.addEventListener("close", () => {
      if (this.socket === socket) {
        this.socket = undefined;
      }
      this.rejectPending(new Error("Action agent connection closed"));
    });
  }

  private launchAgent(): Promise<ChildProcess> {
    return new Promise<ChildProcess>((resolvePromise, reject) => {
      const child = spawn(
        this.launcherPath,
        ["agent", "--port", String(this.port), "--idle-exit-seconds", "5"],
        { detached: true, stdio: "ignore" },
      );
      child.once("error", reject);
      child.once("spawn", () => {
        child.unref();
        resolvePromise(child);
      });
    });
  }

  private rejectPending(error: Error): void {
    for (const request of this.pending.values()) {
      clearTimeout(request.timeout);
      request.reject(error);
    }
    this.pending.clear();
  }
}

const CONNECT_BACKOFF_MIN_MS = 150;
const CONNECT_BACKOFF_MAX_MS = 2_000;
const STUCK_OWNER_GRACE_MS = 3_000;
/** A younger owner may still be starting up; never reap it. */
const STUCK_OWNER_MIN_AGE_SECONDS = 30;
const PING_TIMEOUT_MS = 5_000;

/** The live Action agent named in the socket lock file, if any. */
export function readAgentOwner(lockPath = `${actionSocketPath()}.lock`): { pid: number; ageSeconds: number } | undefined {
  let pid: number;
  try {
    pid = Number.parseInt(readFileSync(lockPath, "utf8").trim(), 10);
  } catch {
    return undefined;
  }
  if (!Number.isInteger(pid) || pid <= 1 || pid === process.pid) return undefined;
  const ps = spawnSync("ps", ["-o", "etime=,command=", "-p", String(pid)], { encoding: "utf8" });
  const line = ps.stdout?.trim();
  if (ps.status !== 0 || !line) return undefined;
  const [etime = "", ...command] = line.split(/\s+/);
  if (!isActionAgentCommand(command.join(" "))) return undefined;
  const ageSeconds = parseElapsed(etime);
  return ageSeconds === undefined ? undefined : { pid, ageSeconds };
}

export function isActionAgentCommand(command: string): boolean {
  return /\/Action(\.app\/Contents\/MacOS\/Action)? agent(\s|$)/.test(command);
}

/** Parse ps `etime`, `[[dd-]hh:]mm:ss`, into seconds. */
export function parseElapsed(etime: string): number | undefined {
  const match = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/.exec(etime);
  if (!match) return undefined;
  const [, days = "0", hours = "0", minutes, seconds] = match;
  return ((Number(days) * 24 + Number(hours)) * 60 + Number(minutes)) * 60 + Number(seconds);
}

async function reapAgent(pid: number): Promise<void> {
  const alive = () => {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  };
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return;
  }
  // A stopped or suspended process can't handle SIGTERM; follow with SIGKILL.
  for (let waited = 0; waited < 2_000 && alive(); waited += 100) await delay(100);
  if (alive()) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      return;
    }
    for (let waited = 0; waited < 2_000 && alive(); waited += 100) await delay(100);
  }
}

export function isDriveLeaseInactiveError(error: unknown): boolean {
  return error instanceof Error
    && /^Drive lease .+ is not active$/.test(error.message);
}

/** Infer the supervision tier from the resolved execution path. */
export function inferAxTier(input: {
  actionKind?: string;
  channel?: string;
  targetMode?: string;
  /**
   * The act will run as a blink act on the agent layer (see `blinkRouteFor`). Blink acts
   * restore the cursor and frontmost app within one act, so they are allowed in
   * background leases instead of needing attention approval.
   */
  blink?: boolean;
}): AxActionTier {
  const channel = input.channel?.toLowerCase();
  const kind = input.actionKind?.toLowerCase() ?? "";
  const targetMode = input.targetMode?.toLowerCase();

  if (input.blink && ["click", "type", "press-key", "drag", "scroll"].includes(kind)) {
    return "blink";
  }

  if (channel === "hid" || targetMode === "coordinate" || kind === "drag") {
    return "attention";
  }
  if (kind === "focus-window" || kind === "open-app") {
    return "target-focus";
  }
  if (channel === "dom" || channel === "tmux" || channel === "editor") {
    return "app-api";
  }
  if (kind === "click" || kind === "type" || kind === "press-key" || kind === "scroll") {
    return "semantic";
  }
  return "observe";
}

function parseAgentJSON<T>(result: Record<string, string>, key: string): T {
  const raw = result[key];
  if (!raw) {
    throw new Error(`Action agent response is missing ${key}`);
  }
  return JSON.parse(raw) as T;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}
