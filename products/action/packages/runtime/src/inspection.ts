import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

import type {
  GuidedSessionPhase,
  HudSnapshot,
  PersistedRuntimeSession,
  SessionArtifactManifest,
} from "@action/protocol";

import { Session } from "./session.js";
import { buildPersistedSession, buildSessionManifest } from "./session-storage.js";
import { CurrentSurfaceSnapshot, MacOSCommandEngine } from "./macos.js";
import type { SurfaceEngine } from "./surface-engine.js";
import type { OCRResult, VisionAnalysisResult } from "./vision.js";
import { analyzeScreenshotVision, ocrScreenshot } from "./vision.js";

function now(): string {
  return new Date().toISOString();
}

function sessionSuffix(): string {
  return now().replace(/[-:.]/g, "").replace("T", "_").replace("Z", "");
}

function outputDirFor(sessionId: string): string {
  return resolve(process.cwd(), "artifacts", "sessions", sessionId);
}

function buildInspectionSnapshot(input: {
  sessionId: string;
  state: HudSnapshot["state"];
  phase: GuidedSessionPhase;
  targetApp?: CurrentSurfaceSnapshot;
  artifacts: HudSnapshot["artifacts"];
}): HudSnapshot {
  return {
    sessionId: input.sessionId,
    mode: "inspection",
    state: input.state,
    phase: input.phase,
    targetApp: input.targetApp?.appName,
    elapsedMs: 0,
    isRecording: false,
    controls: [],
    logs: [],
    artifacts: input.artifacts,
    stage: {
      backdrop: "neutral",
      targetApp: input.targetApp
        ? {
            name: input.targetApp.appName,
            bundleId: input.targetApp.bundleId,
          }
        : undefined,
    },
  };
}

async function persistInspectionFiles(input: {
  outputDir: string;
  session: Session;
  phase: GuidedSessionPhase;
  targetApp?: CurrentSurfaceSnapshot;
}): Promise<{
  manifest: SessionArtifactManifest;
  sessionRecord: PersistedRuntimeSession;
}> {
  const tracePath = resolve(input.outputDir, "trace.json");
  const manifestPath = resolve(input.outputDir, "manifest.json");
  const sessionPath = resolve(input.outputDir, "session.json");
  const trace = input.session.trace();
  const sessionSnapshot = input.session.snapshot();
  const hudSnapshot = buildInspectionSnapshot({
    sessionId: sessionSnapshot.id,
    state: sessionSnapshot.state,
    phase: input.phase,
    targetApp: input.targetApp,
    artifacts: input.session.artifacts(),
  });
  const manifest = buildSessionManifest({
    sessionId: sessionSnapshot.id,
    mode: sessionSnapshot.mode,
    generatedAt: now(),
    outputDir: input.outputDir,
    tracePath,
    artifacts: hudSnapshot.artifacts,
  });
  const sessionRecord = buildPersistedSession({
    mode: sessionSnapshot.mode,
    outputDir: input.outputDir,
    tracePath,
    manifestPath,
    snapshot: hudSnapshot,
    createdAt: sessionSnapshot.createdAt,
    updatedAt: sessionSnapshot.updatedAt,
    trace,
  });

  await writeFile(tracePath, JSON.stringify(trace, null, 2));
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  await writeFile(sessionPath, JSON.stringify(sessionRecord, null, 2));

  return {
    manifest,
    sessionRecord,
  };
}

export interface InspectCurrentSurfaceOptions {
  engine?: SurfaceEngine;
  outputDir?: string;
  sessionId?: string;
  includeOcr?: boolean;
  includeVision?: boolean;
  visionPrompt?: string;
  visionProvider?: "moondream";
}

export interface InspectCurrentSurfaceResult {
  currentSurface: CurrentSurfaceSnapshot;
  manifest: SessionArtifactManifest;
  session: PersistedRuntimeSession;
  ocr?: OCRResult;
  vision?: VisionAnalysisResult;
}

export async function inspectCurrentSurface(
  options: InspectCurrentSurfaceOptions = {},
): Promise<InspectCurrentSurfaceResult> {
  const sessionId = options.sessionId ?? `inspection_current_surface_${sessionSuffix()}`;
  const outputDir = options.outputDir ?? outputDirFor(sessionId);
  const engine: SurfaceEngine = options.engine ?? new MacOSCommandEngine();
  const session = new Session(sessionId, "inspection");
  let phase: GuidedSessionPhase = "created";
  let currentSurface: CurrentSurfaceSnapshot | undefined;
  let ocr: OCRResult | undefined;
  let vision: VisionAnalysisResult | undefined;

  await mkdir(outputDir, { recursive: true });

  try {
    session.transition("preflight", { reason: "resolve current surface" });
    phase = "observing";

    currentSurface = await engine.currentSurface();
    session.recordObservation({
      kind: "window",
      source: "engine",
      at: now(),
      surfaceId: currentSurface.surface.id,
      data: {
        bundleId: currentSurface.bundleId,
        appName: currentSurface.appName,
        bounds: currentSurface.surface.bounds,
      },
    });

    const surfacePath = resolve(outputDir, "surface.json");
    await writeFile(surfacePath, JSON.stringify(currentSurface, null, 2));
    session.registerArtifact({
      kind: "focus-metadata",
      path: surfacePath,
      metadata: {
        bundleId: currentSurface.bundleId,
        appName: currentSurface.appName,
        surfaceId: currentSurface.surface.id,
      },
    });

    session.transition("ready", { reason: "current surface resolved" });
    session.transition("running", { reason: "capture current surface snapshot" });

    const screenshotPath = resolve(outputDir, "snapshot.png");
    const screenshot = await engine.captureSurfaceScreenshot(currentSurface, screenshotPath);
    session.registerArtifact(screenshot);

    // An accessibility tree exists only on macOS; a remote host has none.
    if (engine.captureSurfaceAccessibilitySnapshot) {
      const axPath = resolve(outputDir, "ax-snapshot.json");
      const axSnapshot = await engine.captureSurfaceAccessibilitySnapshot(currentSurface, axPath);
      session.recordObservation({
        kind: "accessibility",
        source: "engine",
        at: now(),
        surfaceId: currentSurface.surface.id,
        data: {
          bundleId: currentSurface.bundleId,
          nodeCount: axSnapshot.nodeCount,
          artifactPath: axPath,
        },
      });
      session.registerArtifact(axSnapshot.artifact);
    }

    if (options.includeOcr !== false) {
      const ocrPath = resolve(outputDir, "ocr-snapshot.json");
      // OCR where the pixels are: the remote host when the engine offers it.
      const ocrCapture = engine.ocrSurface
        ? await engine.ocrSurface(currentSurface, screenshotPath, ocrPath)
        : await ocrScreenshot(screenshotPath, ocrPath);
      ocr = ocrCapture.result;
      session.recordObservation({
        kind: "vision",
        source: "engine",
        at: now(),
        surfaceId: currentSurface.surface.id,
        data: {
          provider: engine.ocrSurface ? "tesseract" : "apple-vision",
          blockCount: ocr.blockCount,
          artifactPath: ocrPath,
        },
      });
      session.registerArtifact(ocrCapture.artifact);
    }

    if (options.includeVision) {
      const visionPath = resolve(outputDir, "vision-analysis.json");
      const visionCapture = await analyzeScreenshotVision(screenshotPath, {
        prompt: options.visionPrompt,
        outputPath: visionPath,
        provider: options.visionProvider,
      });
      vision = visionCapture.result;
      session.recordObservation({
        kind: "analysis",
        source: "runtime",
        at: now(),
        surfaceId: currentSurface.surface.id,
        data: {
          provider: vision.provider,
          available: vision.available,
          summary: vision.summary,
          artifactPath: visionPath,
        },
      });
      session.registerArtifact(visionCapture.artifact);
    }

    session.transition("completing", { reason: "persist inspection session" });
    session.transition("completed", { reason: "inspection snapshot complete" });
    phase = "completed";
  } catch (error) {
    const state = session.snapshot().state;
    if (!["completed", "failed", "cancelled"].includes(state)) {
      session.transition("failed", { reason: error instanceof Error ? error.message : "inspection failed" });
    }
    phase = "failed";
    await persistInspectionFiles({
      outputDir,
      session,
      phase,
      targetApp: currentSurface,
    });
    throw error;
  }

  const { manifest, sessionRecord } = await persistInspectionFiles({
    outputDir,
    session,
    phase,
    targetApp: currentSurface,
  });

  return {
    currentSurface: currentSurface!,
    manifest,
    session: sessionRecord,
    ocr,
    vision,
  };
}
