import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
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
      await this.launchAgent();
    }

    const deadline = Date.now() + this.startupTimeoutMs;
    let lastError: unknown;
    while (Date.now() < deadline) {
      try {
        return await this.connectOnce(500);
      } catch (error) {
        lastError = error;
        await delay(150);
      }
    }
    throw new Error(
      `Action agent did not start within ${this.startupTimeoutMs}ms: ${String(lastError)}`,
    );
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

  private launchAgent(): Promise<void> {
    return new Promise<void>((resolvePromise, reject) => {
      const child = spawn(
        this.launcherPath,
        ["agent", "--port", String(this.port), "--idle-exit-seconds", "5"],
        { detached: true, stdio: "ignore" },
      );
      child.once("error", reject);
      child.once("spawn", () => {
        child.unref();
        resolvePromise();
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
