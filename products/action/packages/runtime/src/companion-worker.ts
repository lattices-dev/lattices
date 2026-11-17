#!/usr/bin/env bun

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { createHash } from "node:crypto";

import { CompanionClient, type CompanionJob } from "./companion-client.js";
import { inspectCurrentSurface } from "./inspection.js";
import { MacOSCommandEngine } from "./macos.js";
import { analyzeScreenshotVision, type VisionProviderId } from "./vision.js";

function now(): string {
  return new Date().toISOString();
}

function timestampId(): string {
  return now().replace(/[-:.]/g, "").replace("T", "_").replace("Z", "");
}

function parseArgs(argv: string[]): Record<string, string> {
  const result: Record<string, string> = {};
  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];
    if (!current.startsWith("--")) {
      continue;
    }
    const key = current.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      result[key] = "true";
      continue;
    }
    result[key] = next;
    index += 1;
  }
  return result;
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function optionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function provider(value: unknown): VisionProviderId | undefined {
  return value === "moondream" ? value : undefined;
}

function sessionOutputDir(actionRoot: string, sessionId: string): string {
  return resolve(actionRoot, "artifacts/sessions", sessionId);
}

async function writeJson(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
}

function mockSurface() {
  return {
    bundleId: "dev.action.mock",
    appName: "Mock Surface",
    surface: {
      id: "surface_mock",
      kind: "window",
      label: "Mock Surface",
      bounds: { x: 0, y: 0, width: 1280, height: 720 },
    },
  };
}

async function mockSnapshot(actionRoot: string, job: CompanionJob): Promise<Record<string, unknown>> {
  const payload = asObject(job.payload);
  const sessionId = optionalString(payload.sessionId) ?? `inspection_mock_${timestampId()}`;
  const outputDir = resolve(actionRoot, optionalString(payload.outputDir) ?? sessionOutputDir(actionRoot, sessionId));
  const currentSurface = mockSurface();
  const createdAt = now();
  const snapshotPath = resolve(outputDir, "snapshot.mock.json");
  const surfacePath = resolve(outputDir, "surface.json");
  const tracePath = resolve(outputDir, "trace.json");
  const manifestPath = resolve(outputDir, "manifest.json");

  await writeJson(snapshotPath, { ok: true, mock: true, createdAt, note: "Native ActionAgent was not required for this mock companion job." });
  await writeJson(surfacePath, currentSurface);
  await writeJson(tracePath, []);

  const manifest = {
    sessionId,
    mode: "inspection",
    generatedAt: createdAt,
    outputDir,
    tracePath,
    artifacts: [
      { kind: "screenshot", path: snapshotPath, relativePath: "snapshot.mock.json", metadata: { mock: true } },
      { kind: "focus-metadata", path: surfacePath, relativePath: "surface.json", metadata: { mock: true } },
    ],
  };
  const session = {
    id: sessionId,
    mode: "inspection",
    state: "completed",
    phase: "completed",
    createdAt,
    updatedAt: createdAt,
    targetApp: currentSurface.appName,
    outputDir,
    tracePath,
    manifestPath,
    artifactCount: manifest.artifacts.length,
    traceCount: 0,
    artifacts: manifest.artifacts,
    stage: {
      backdrop: "neutral",
      targetApp: { name: currentSurface.appName, bundleId: currentSurface.bundleId },
    },
  };
  await writeJson(manifestPath, manifest);
  await writeJson(resolve(outputDir, "session.json"), session);

  return {
    ok: true,
    mock: true,
    currentSurface,
    manifest,
    session,
  };
}

async function mockVision(actionRoot: string, job: CompanionJob): Promise<Record<string, unknown>> {
  const payload = asObject(job.payload);
  const sessionId = optionalString(payload.sessionId) ?? `vision_mock_${timestampId()}`;
  const outputDir = resolve(actionRoot, optionalString(payload.outputDir) ?? sessionOutputDir(actionRoot, sessionId));
  const imagePath = resolve(outputDir, "snapshot.mock.json");
  const outputPath = resolve(outputDir, "vision-analysis.json");
  await writeJson(imagePath, { ok: true, mock: true, createdAt: now() });
  const result = {
    available: true,
    provider: provider(payload.provider) ?? "moondream",
    imagePath,
    model: "mock",
    summary: "Mock vision observation from action-companion.",
    answer: "Mock vision observation from action-companion.",
    parsed: { summary: "Mock vision observation from action-companion.", elements: [], buttons: [], errors: [] },
    timingMs: { total: 0 },
  };
  await writeJson(outputPath, result);
  return {
    ok: true,
    mock: true,
    artifact: {
      kind: "vision-analysis",
      path: outputPath,
      metadata: { imagePath, available: true, provider: result.provider, model: result.model, mock: true },
    },
    vision: result,
  };
}

function shouldUseMock(payload: Record<string, unknown>): boolean {
  return optionalBoolean(payload.mockNative) === true || process.env.ACTION_COMPANION_MOCK_NATIVE === "1";
}

async function executeObserveSnapshot(actionRoot: string, job: CompanionJob): Promise<unknown> {
  const payload = asObject(job.payload);
  if (shouldUseMock(payload)) {
    return mockSnapshot(actionRoot, job);
  }

  return inspectCurrentSurface({
    engine: new MacOSCommandEngine(optionalString(payload.nativeHostPath)),
    sessionId: optionalString(payload.sessionId),
    outputDir: optionalString(payload.outputDir),
    includeOcr: payload.includeOcr === false ? false : true,
    includeVision: payload.includeVision === true,
    visionPrompt: optionalString(payload.visionPrompt),
    visionProvider: provider(payload.visionProvider),
  });
}

async function executeObserveVision(actionRoot: string, job: CompanionJob): Promise<unknown> {
  const payload = asObject(job.payload);
  if (shouldUseMock(payload)) {
    return mockVision(actionRoot, job);
  }

  let imagePath = optionalString(payload.imagePath);
  let currentSurface: unknown;
  if (!imagePath) {
    const sessionId = optionalString(payload.sessionId) ?? `vision_${timestampId()}`;
    const outputDir = resolve(actionRoot, optionalString(payload.outputDir) ?? sessionOutputDir(actionRoot, sessionId));
    const capture = await new MacOSCommandEngine(optionalString(payload.nativeHostPath)).captureCurrentSurfaceScreenshot(resolve(outputDir, "snapshot.png"));
    imagePath = capture.artifact.path;
    currentSurface = capture.currentSurface;
  } else {
    imagePath = resolve(actionRoot, imagePath);
  }

  const outputPath = resolve(actionRoot, optionalString(payload.outputPath) ?? `${imagePath}.vision.json`);
  const result = await analyzeScreenshotVision(imagePath, {
    prompt: optionalString(payload.prompt) ?? optionalString(payload.visionPrompt),
    outputPath,
    provider: provider(payload.provider) ?? provider(payload.visionProvider),
  });

  return {
    ok: true,
    currentSurface,
    promptHash: optionalString(payload.prompt) ? createHash("sha256").update(String(payload.prompt)).digest("hex").slice(0, 16) : undefined,
    artifact: result.artifact,
    vision: result.result,
  };
}

async function executeJob(actionRoot: string, job: CompanionJob): Promise<unknown> {
  switch (job.kind) {
    case "observe.snapshot":
      return executeObserveSnapshot(actionRoot, job);
    case "observe.vision":
      return executeObserveVision(actionRoot, job);
    default:
      throw new Error(`Unsupported companion job kind: ${job.kind}`);
  }
}

export async function main(argv = process.argv.slice(2)): Promise<void> {
  const args = parseArgs(argv);
  const jobId = args.job;
  if (!jobId) {
    throw new Error("Missing --job");
  }
  const actionRoot = resolve(args.root ?? process.env.ACTION_ROOT ?? resolve(dirname(new URL(import.meta.url).pathname), "../../.."));
  const client = new CompanionClient({ baseUrl: args["base-url"] ?? process.env.ACTION_COMPANION_BASE_URL });

  try {
    const job = await client.getJob(jobId);
    await client.appendJobEvent(jobId, { level: "info", type: "worker.started", message: `Executing ${job.kind}` });
    const result = await executeJob(actionRoot, job);
    await client.appendJobEvent(jobId, { level: "info", type: "worker.completed", message: `Completed ${job.kind}` });
    await client.completeJob(jobId, result);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    try {
      await client.appendJobEvent(jobId, { level: "error", type: "worker.failed", message });
      await client.failJob(jobId, message);
    } catch {}
    process.exitCode = 1;
  }
}

if (import.meta.main) {
  void main();
}
