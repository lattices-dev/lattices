#!/usr/bin/env bun

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { existsSync, mkdirSync, rmSync, chmodSync, lstatSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { createConnection } from "node:net";
import { companionTokenPath, ensurePrivateToken, secureDirectory, tokenMatches } from "../../runtime/src/local-security.js";

import { ActionCompanionDatabase, DB_SCHEMA_VERSION, RPC_VERSION, type JobRecord } from "./db.js";
import { ActionCompanionQueue } from "./queue.js";
import { loadCompanionSecrets } from "./secrets.js";

const startedAt = new Date().toISOString();

interface CompanionConfig {
  actionRoot: string;
  supportDirectory: string;
  runtimeDirectory: string;
  databasePath: string;
  socketPath: string;
  port?: number;
  host: string;
}

function repoRootFromSource(): string {
  return resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
}

function defaultSupportDirectory(): string {
  return resolve(homedir(), "Library/Application Support/Action");
}

function resolveConfig(): CompanionConfig {
  const actionRoot = resolve(process.env.ACTION_ROOT ?? repoRootFromSource());
  const supportDirectory = resolve(process.env.ACTION_SUPPORT_DIRECTORY ?? process.env.ACTION_COMPANION_SUPPORT_DIRECTORY ?? defaultSupportDirectory());
  const runtimeDirectory = resolve(process.env.ACTION_COMPANION_RUNTIME_DIRECTORY ?? resolve(supportDirectory, "runtime"));
  const databasePath = resolve(process.env.ACTION_COMPANION_DB_PATH ?? resolve(supportDirectory, "action-companion.sqlite"));
  const socketPath = resolve(process.env.ACTION_COMPANION_SOCKET_PATH ?? resolve(runtimeDirectory, "companion.sock"));
  const portRaw = process.env.ACTION_COMPANION_PORT;
  const port = process.env.ACTION_COMPANION_ALLOW_TCP === "1" && portRaw ? Number(portRaw) : undefined;
  if (port !== undefined && (!Number.isInteger(port) || port < 1 || port > 65535)) throw new Error("Invalid companion TCP port");
  if (process.env.ACTION_COMPANION_HOST && process.env.ACTION_COMPANION_HOST !== "127.0.0.1") throw new Error("Companion TCP compatibility is loopback only");
  return {
    actionRoot,
    supportDirectory,
    runtimeDirectory,
    databasePath,
    socketPath,
    port: Number.isFinite(port) ? port : undefined,
    host: process.env.ACTION_COMPANION_HOST ?? "127.0.0.1",
  };
}

function json(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function sendJson(response: ServerResponse, status: number, value: unknown): void {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  response.end(json(value));
}

async function readBody(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of request) {
    length += Buffer.byteLength(chunk);
    if (length > 1_048_576) throw new Error("Request body exceeds 1 MiB");
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  const text = Buffer.concat(chunks).toString("utf8").trim();
  if (!text) {
    return {};
  }
  return JSON.parse(text) as unknown;
}

function asObject(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, unknown>;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function optionalNumber(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

function terminalJob(job: JobRecord): boolean {
  return job.state === "completed" || job.state === "failed" || job.state === "cancelled";
}

function hashPrompt(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0
    ? createHash("sha256").update(value).digest("hex").slice(0, 16)
    : undefined;
}

function indexJobResult(db: ActionCompanionDatabase, job: JobRecord, result: unknown): void {
  const record = asObject(result);
  const session = asObject(record.session);
  const manifest = asObject(record.manifest);
  const currentSurface = asObject(record.currentSurface);
  const ocr = asObject(record.ocr);
  const vision = asObject(record.vision);
  const directArtifact = asObject(record.artifact);
  const sessionId = optionalString(session.id) ?? job.sessionId ?? optionalString(record.sessionId);
  const artifactRoot = optionalString(session.outputDir) ?? optionalString(manifest.outputDir);

  if (sessionId) {
    db.upsertSession({
      id: sessionId,
      mode: optionalString(session.mode),
      state: optionalString(session.state),
      artifactRoot,
      createdAt: optionalString(session.createdAt),
      updatedAt: optionalString(session.updatedAt),
    });
  }

  const artifacts = Array.isArray(manifest.artifacts) ? manifest.artifacts : [];
  const artifactIdsByPath = new Map<string, string>();
  for (const artifactValue of artifacts) {
    const artifact = asObject(artifactValue);
    const path = optionalString(artifact.path);
    const kind = optionalString(artifact.kind);
    if (!path || !kind) {
      continue;
    }
    const saved = db.upsertArtifact({
      sessionId,
      jobId: job.id,
      kind,
      path,
      metadata: artifact.metadata,
    });
    artifactIdsByPath.set(path, saved.id);
  }

  const directArtifactPath = optionalString(directArtifact.path);
  if (directArtifactPath && optionalString(directArtifact.kind)) {
    const saved = db.upsertArtifact({
      sessionId,
      jobId: job.id,
      kind: optionalString(directArtifact.kind)!,
      path: directArtifactPath,
      metadata: directArtifact.metadata,
    });
    artifactIdsByPath.set(directArtifactPath, saved.id);
  }

  if (Object.keys(currentSurface).length > 0) {
    const surface = asObject(currentSurface.surface);
    db.addObservation({
      sessionId,
      jobId: job.id,
      surfaceId: optionalString(surface.id),
      kind: "window",
      source: "runtime",
      summary: optionalString(currentSurface.appName),
      data: currentSurface,
    });
  }

  if (Object.keys(ocr).length > 0) {
    db.addObservation({
      sessionId,
      jobId: job.id,
      kind: "vision",
      source: "engine",
      summary: optionalString(ocr.fullText)?.slice(0, 500),
      data: ocr,
    });
  }

  if (Object.keys(vision).length > 0) {
    const imagePath = optionalString(vision.imagePath);
    db.addVisionTimeline({
      sessionId,
      jobId: job.id,
      imageArtifactId: imagePath ? artifactIdsByPath.get(imagePath) : undefined,
      provider: optionalString(vision.provider),
      model: optionalString(vision.model),
      promptHash: hashPrompt(asObject(job.payload).prompt ?? asObject(job.payload).visionPrompt),
      summary: optionalString(vision.summary) ?? optionalString(vision.answer)?.slice(0, 500),
      result: vision,
    });
    db.addObservation({
      sessionId,
      jobId: job.id,
      kind: "analysis",
      source: "runtime",
      summary: optionalString(vision.summary),
      data: vision,
    });
  }
}

function createHandler(input: { config: CompanionConfig; db: ActionCompanionDatabase; queue: ActionCompanionQueue; secretsLoadedAt: string; token: string }) {
  const { config, db, queue, secretsLoadedAt } = input;
  const capabilities = {
    rpcVersion: RPC_VERSION,
    dbSchemaVersion: DB_SCHEMA_VERSION,
    jobKinds: ["observe.snapshot", "observe.vision"],
    transports: ["unix-socket", ...(config.port ? ["tcp"] : [])],
  };

  return async function handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    try {
      const headerNames = request.rawHeaders.filter((_, index) => index % 2 === 0).map(name => name.toLowerCase());
      if (headerNames.filter(name => name === "host").length !== 1 ||
          headerNames.filter(name => name === "x-lattices-token").length !== 1 ||
          request.headers.origin !== undefined || !tokenMatches(request.headers["x-lattices-token"], input.token)) {
        sendJson(response, 401, { ok: false, error: "Authenticated local IPC required" }); return;
      }
      const host = request.headers.host;
      const allowedHosts = request.socket.remoteAddress
        ? [`127.0.0.1:${config.port}`, `localhost:${config.port}`] : ["localhost"];
      if (!host || !allowedHosts.includes(host)) {
        sendJson(response, 403, { ok: false, error: "Invalid Host" }); return;
      }
      const url = new URL(request.url ?? "/", "http://action-companion.local");
      const method = request.method ?? "GET";
      const parts = url.pathname.split("/").filter(Boolean);

      if (method === "GET" && url.pathname === "/health") {
        sendJson(response, 200, {
          ok: true,
          service: "action-companion",
          startedAt,
          rpcVersion: RPC_VERSION,
          dbSchemaVersion: DB_SCHEMA_VERSION,
        });
        return;
      }

      if (method === "GET" && url.pathname === "/v1/status") {
        sendJson(response, 200, {
          ok: true,
          service: "action-companion",
          startedAt,
          actionRoot: config.actionRoot,
          supportDirectory: config.supportDirectory,
          databasePath: config.databasePath,
          socketPath: config.socketPath,
          port: config.port,
          queue: queue.stats(),
          capabilities,
        });
        return;
      }

      if (method === "GET" && url.pathname === "/v1/capabilities") {
        sendJson(response, 200, { ok: true, capabilities });
        return;
      }

      if (method === "GET" && url.pathname === "/v1/secrets/status") {
        sendJson(response, 200, { ok: true, loadedAt: secretsLoadedAt, secrets: db.secretStatuses() });
        return;
      }

      if (method === "POST" && url.pathname === "/v1/jobs") {
        const body = asObject(await readBody(request));
        const kind = optionalString(body.kind);
        if (!kind) {
          sendJson(response, 400, { ok: false, error: "kind is required" });
          return;
        }
        const payload = asObject(body.payload);
        const job = queue.enqueue({
          kind,
          payload,
          priority: optionalNumber(body.priority),
          sessionId: optionalString(body.sessionId) ?? optionalString(payload.sessionId),
          idempotencyKey: optionalString(body.idempotencyKey),
          maxAttempts: optionalNumber(body.maxAttempts),
        });
        db.recordOperatorHistory({
          actor: optionalString(body.actor) ?? "local",
          client: optionalString(body.client) ?? "rpc",
          command: `jobs.create:${kind}`,
          request: body,
          jobId: job.id,
          resultSummary: job.state,
        });
        sendJson(response, 202, { ok: true, job });
        return;
      }

      if (method === "GET" && url.pathname === "/v1/jobs") {
        sendJson(response, 200, {
          ok: true,
          jobs: db.listJobs({
            state: optionalString(url.searchParams.get("state")),
            limit: optionalNumber(url.searchParams.get("limit")),
          }),
        });
        return;
      }

      if (parts[0] === "v1" && parts[1] === "jobs" && parts[2]) {
        const jobId = parts[2];
        if (method === "GET" && parts.length === 3) {
          const job = db.getJob(jobId);
          if (!job) {
            sendJson(response, 404, { ok: false, error: `Unknown job ${jobId}` });
            return;
          }
          sendJson(response, 200, { ok: true, job });
          return;
        }

        if (method === "POST" && parts[3] === "cancel") {
          const body = asObject(await readBody(request));
          const job = queue.cancel(jobId, optionalString(body.reason));
          sendJson(response, 200, { ok: true, job });
          return;
        }

        if (method === "POST" && parts[3] === "wait") {
          const body = asObject(await readBody(request));
          const job = await queue.wait(jobId, optionalNumber(body.timeoutMs) ?? 60_000);
          sendJson(response, terminalJob(job) ? 200 : 202, { ok: terminalJob(job), job });
          return;
        }

        if (method === "GET" && parts[3] === "events") {
          sendJson(response, 200, {
            ok: true,
            events: db.jobEvents(jobId, optionalNumber(url.searchParams.get("limit")) ?? 200),
          });
          return;
        }

        if (method === "POST" && parts[3] === "events") {
          const body = asObject(await readBody(request));
          const event = db.addJobEvent(jobId, {
            level: optionalString(body.level) as never,
            type: optionalString(body.type) ?? "worker.event",
            message: optionalString(body.message),
            data: body.data,
          });
          sendJson(response, 200, { ok: true, event });
          return;
        }

        if (method === "POST" && parts[3] === "result") {
          const body = asObject(await readBody(request));
          const state = body.state === "cancelled" ? "cancelled" : body.ok === false || body.state === "failed" ? "failed" : "completed";
          const before = db.requireJob(jobId);
          if (state === "completed") {
            indexJobResult(db, before, body.result);
          }
          const job = db.finishJob(jobId, {
            state,
            result: body.result,
            error: optionalString(body.error),
          });
          sendJson(response, 200, { ok: state === "completed", job });
          return;
        }
      }

      if (method === "GET" && url.pathname === "/v1/timeline") {
        sendJson(response, 200, {
          ok: true,
          timeline: db.visionTimeline({
            sessionId: optionalString(url.searchParams.get("sessionId")),
            limit: optionalNumber(url.searchParams.get("limit")),
          }),
        });
        return;
      }

      if (method === "GET" && url.pathname === "/v1/artifacts") {
        sendJson(response, 200, {
          ok: true,
          artifacts: db.artifacts({
            sessionId: optionalString(url.searchParams.get("sessionId")),
            kind: optionalString(url.searchParams.get("kind")),
            limit: optionalNumber(url.searchParams.get("limit")),
          }),
        });
        return;
      }

      if (method === "GET" && url.pathname === "/v1/operator-history") {
        sendJson(response, 200, { ok: true, history: db.operatorHistory(optionalNumber(url.searchParams.get("limit"))) });
        return;
      }

      sendJson(response, 404, { ok: false, error: `Not found: ${method} ${url.pathname}` });
    } catch (error) {
      sendJson(response, 500, {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  };
}

export async function main(): Promise<void> {
  const config = resolveConfig();
  secureDirectory(config.runtimeDirectory);
  secureDirectory(dirname(config.socketPath));
  const token = ensurePrivateToken(companionTokenPath());
  mkdirSync(dirname(config.databasePath), { recursive: true });

  const db = new ActionCompanionDatabase(config.databasePath);
  const secrets = loadCompanionSecrets({ db });
  const queue = new ActionCompanionQueue(db, {
    actionRoot: config.actionRoot,
    companionBaseUrl: `unix:${config.socketPath}`,
  });
  const handler = createHandler({ config, db, queue, secretsLoadedAt: secrets.loadedAt, token });
  const unixServer = createServer((request, response) => {
    void handler(request, response);
  });
  const tcpServer = config.port
    ? createServer((request, response) => {
      void handler(request, response);
    })
    : undefined;

  for (const server of [unixServer, tcpServer]) {
    if (server) { server.requestTimeout = 10_000; server.headersTimeout = 5_000; server.maxHeadersCount = 32; }
  }
  if (existsSync(config.socketPath)) {
    const info = lstatSync(config.socketPath);
    if (!info.isSocket() || info.uid !== process.getuid?.()) throw new Error("Refusing to replace a non-owned companion socket");
    const active = await new Promise<boolean>((resolve) => {
      const socket = createConnection(config.socketPath);
      socket.once("connect", () => { socket.destroy(); resolve(true); });
      socket.once("error", (error: NodeJS.ErrnoException) => { socket.destroy(); resolve(error.code !== "ECONNREFUSED" && error.code !== "ENOENT"); });
      socket.setTimeout(500, () => { socket.destroy(); resolve(true); });
    });
    if (active) throw new Error("Companion socket is already active");
    rmSync(config.socketPath);
  }

  await new Promise<void>((resolvePromise, reject) => {
    unixServer.once("error", reject);
    unixServer.listen(config.socketPath, () => { chmodSync(config.socketPath, 0o600); resolvePromise(); });
  });
  if (tcpServer && config.port) {
    await new Promise<void>((resolvePromise, reject) => {
      tcpServer.once("error", reject);
      tcpServer.listen(config.port, config.host, resolvePromise);
    });
  }

  queue.start();
  process.stdout.write(json({
    ok: true,
    service: "action-companion",
    socketPath: config.socketPath,
    port: config.port,
    databasePath: config.databasePath,
    startedAt,
  }));

  const shutdown = () => {
    queue.stop();
    unixServer.close();
    tcpServer?.close();
    db.close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

if (import.meta.main) {
  void main();
}
