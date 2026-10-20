import { request as httpRequest } from "node:http";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { companionTokenPath, readPrivateToken } from "./local-security.js";

export type CompanionJobState = "queued" | "running" | "cancelling" | "cancelled" | "completed" | "failed";

export interface CompanionJob<TPayload = Record<string, unknown>, TResult = unknown> {
  id: string;
  kind: string;
  state: CompanionJobState;
  priority: number;
  payload: TPayload;
  result?: TResult;
  error?: string;
  sessionId?: string;
  idempotencyKey?: string;
  attempts: number;
  maxAttempts: number;
  createdAt: string;
  updatedAt: string;
  startedAt?: string;
  finishedAt?: string;
  workerPid?: number;
  leaseUntil?: string;
}

export interface CompanionJobEvent {
  id: string;
  jobId: string;
  at: string;
  level: "debug" | "info" | "warn" | "error";
  type: string;
  message?: string;
  data?: unknown;
}

export interface CompanionHealth {
  ok: boolean;
  service: string;
  startedAt: string;
  rpcVersion: number;
  dbSchemaVersion: number;
}

export interface CompanionStatus {
  ok: boolean;
  service: string;
  startedAt: string;
  actionRoot: string;
  supportDirectory: string;
  databasePath: string;
  socketPath: string;
  port?: number;
  queue: unknown;
  capabilities: unknown;
}

export interface CompanionClientOptions {
  baseUrl?: string;
  socketPath?: string;
  timeoutMs?: number;
}

function defaultSocketPath(): string {
  return resolve(
    process.env.ACTION_COMPANION_SOCKET_PATH
      ?? resolve(process.env.ACTION_SUPPORT_DIRECTORY ?? process.env.ACTION_COMPANION_SUPPORT_DIRECTORY ?? resolve(homedir(), "Library/Application Support/Action"), "runtime/companion.sock"),
  );
}

export function resolveCompanionBaseUrl(): string {
  return process.env.ACTION_COMPANION_URL ?? `unix:${defaultSocketPath()}`;
}

function parseBaseUrl(baseUrl: string): { socketPath?: string; url?: URL } {
  if (baseUrl.startsWith("unix:")) {
    return { socketPath: baseUrl.slice("unix:".length) };
  }
  return { url: new URL(baseUrl) };
}

function bodyText(value: unknown): string | undefined {
  return value === undefined ? undefined : JSON.stringify(value);
}

export class CompanionClient {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;

  constructor(options: CompanionClientOptions = {}) {
    this.baseUrl = options.baseUrl ?? (options.socketPath ? `unix:${options.socketPath}` : resolveCompanionBaseUrl());
    this.timeoutMs = options.timeoutMs ?? 2_000;
  }

  async health(): Promise<CompanionHealth> {
    return this.request("GET", "/health");
  }

  async isReachable(): Promise<boolean> {
    try {
      const health = await this.health();
      return health.ok === true;
    } catch {
      return false;
    }
  }

  async status(): Promise<CompanionStatus> {
    return this.request("GET", "/v1/status");
  }

  async capabilities(): Promise<unknown> {
    return this.request("GET", "/v1/capabilities");
  }

  async createJob<TPayload extends Record<string, unknown> = Record<string, unknown>>(input: {
    kind: string;
    payload?: TPayload;
    priority?: number;
    sessionId?: string;
    idempotencyKey?: string;
    maxAttempts?: number;
    client?: string;
    actor?: string;
  }): Promise<CompanionJob<TPayload>> {
    const response = await this.request<{ ok: boolean; job: CompanionJob<TPayload> }>("POST", "/v1/jobs", input);
    return response.job;
  }

  async listJobs(input: { state?: string; limit?: number } = {}): Promise<CompanionJob[]> {
    const search = new URLSearchParams();
    if (input.state) search.set("state", input.state);
    if (input.limit) search.set("limit", String(input.limit));
    const suffix = search.size > 0 ? `?${search.toString()}` : "";
    const response = await this.request<{ ok: boolean; jobs: CompanionJob[] }>("GET", `/v1/jobs${suffix}`);
    return response.jobs;
  }

  async getJob<TResult = unknown>(id: string): Promise<CompanionJob<Record<string, unknown>, TResult>> {
    const response = await this.request<{ ok: boolean; job: CompanionJob<Record<string, unknown>, TResult> }>("GET", `/v1/jobs/${encodeURIComponent(id)}`);
    return response.job;
  }

  async cancelJob(id: string, reason?: string): Promise<CompanionJob> {
    const response = await this.request<{ ok: boolean; job: CompanionJob }>("POST", `/v1/jobs/${encodeURIComponent(id)}/cancel`, { reason });
    return response.job;
  }

  async waitJob<TResult = unknown>(id: string, timeoutMs = 60_000): Promise<CompanionJob<Record<string, unknown>, TResult>> {
    const response = await this.request<{ ok: boolean; job: CompanionJob<Record<string, unknown>, TResult> }>("POST", `/v1/jobs/${encodeURIComponent(id)}/wait`, { timeoutMs }, Math.max(this.timeoutMs, timeoutMs + 1_000));
    return response.job;
  }

  async jobEvents(id: string): Promise<CompanionJobEvent[]> {
    const response = await this.request<{ ok: boolean; events: CompanionJobEvent[] }>("GET", `/v1/jobs/${encodeURIComponent(id)}/events`);
    return response.events;
  }

  async appendJobEvent(id: string, event: { level?: string; type: string; message?: string; data?: unknown }): Promise<CompanionJobEvent> {
    const response = await this.request<{ ok: boolean; event: CompanionJobEvent }>("POST", `/v1/jobs/${encodeURIComponent(id)}/events`, event);
    return response.event;
  }

  async completeJob(id: string, result: unknown): Promise<CompanionJob> {
    const response = await this.request<{ ok: boolean; job: CompanionJob }>("POST", `/v1/jobs/${encodeURIComponent(id)}/result`, { ok: true, state: "completed", result });
    return response.job;
  }

  async failJob(id: string, error: string, result?: unknown): Promise<CompanionJob> {
    const response = await this.request<{ ok: boolean; job: CompanionJob }>("POST", `/v1/jobs/${encodeURIComponent(id)}/result`, { ok: false, state: "failed", error, result });
    return response.job;
  }

  async timeline(input: { sessionId?: string; limit?: number } = {}): Promise<unknown[]> {
    const search = new URLSearchParams();
    if (input.sessionId) search.set("sessionId", input.sessionId);
    if (input.limit) search.set("limit", String(input.limit));
    const suffix = search.size > 0 ? `?${search.toString()}` : "";
    const response = await this.request<{ ok: boolean; timeline: unknown[] }>("GET", `/v1/timeline${suffix}`);
    return response.timeline;
  }

  async artifacts(input: { sessionId?: string; kind?: string; limit?: number } = {}): Promise<unknown[]> {
    const search = new URLSearchParams();
    if (input.sessionId) search.set("sessionId", input.sessionId);
    if (input.kind) search.set("kind", input.kind);
    if (input.limit) search.set("limit", String(input.limit));
    const suffix = search.size > 0 ? `?${search.toString()}` : "";
    const response = await this.request<{ ok: boolean; artifacts: unknown[] }>("GET", `/v1/artifacts${suffix}`);
    return response.artifacts;
  }

  async secretStatus(): Promise<unknown> {
    return this.request("GET", "/v1/secrets/status");
  }

  async request<T>(method: string, path: string, body?: unknown, timeoutMs = this.timeoutMs): Promise<T> {
    const base = parseBaseUrl(this.baseUrl);
    const payload = bodyText(body);
    if (base.url && (process.env.ACTION_COMPANION_ALLOW_TCP !== "1" || base.url.protocol !== "http:" || !["localhost", "127.0.0.1"].includes(base.url.hostname))) throw new Error("Companion local TCP is disabled; use private IPC or the remote gateway");
    const headers = { "Host": base.socketPath ? "localhost" : base.url!.host, "x-lattices-token": readPrivateToken(companionTokenPath()), ...(payload ? { "content-type": "application/json", "content-length": Buffer.byteLength(payload) } : {}) };

    return new Promise<T>((resolvePromise, reject) => {
      const timeout = setTimeout(() => {
        req.destroy(new Error(`Action companion request timed out after ${timeoutMs}ms`));
      }, timeoutMs);

      const requestOptions = base.socketPath
        ? {
          socketPath: base.socketPath,
          path,
          method,
          headers,
        }
        : {
          protocol: base.url!.protocol,
          hostname: base.url!.hostname,
          port: base.url!.port,
          path,
          method,
          headers,
        };

      const req = httpRequest(requestOptions, (response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
        response.on("end", () => {
          clearTimeout(timeout);
          const text = Buffer.concat(chunks).toString("utf8");
          let parsed: unknown;
          try {
            parsed = text ? JSON.parse(text) : {};
          } catch (error) {
            reject(error);
            return;
          }
          if ((response.statusCode ?? 500) >= 400) {
            const error = new Error(typeof (parsed as { error?: unknown }).error === "string" ? (parsed as { error: string }).error : `Action companion HTTP ${response.statusCode}`);
            reject(error);
            return;
          }
          resolvePromise(parsed as T);
        });
      });
      req.on("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      if (payload) {
        req.write(payload);
      }
      req.end();
    });
  }
}
