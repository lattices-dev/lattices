import { execFile } from "node:child_process";
import type { SurfaceEngine } from "./surface-engine.js";
import { access, mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { promisify } from "node:util";

import type {
  BackdropPreset,
  Bounds,
  CaptureEngine,
  CaptureProfile,
  ClickFeedbackConfig,
  EngineDiagnostics,
  Point,
  ResolvedTarget,
  RuntimeAction,
  RuntimeArtifact,
  StagePresentation,
  StageViewport,
  SurfaceRef,
  TargetApp,
  TargetQuery,
} from "@action/protocol";
import {
  blinkRouteFor,
  executeInteractionAction,
  type AgentLayerRouting,
  type BlinkRoute,
  type InteractionExecutionContext,
} from "./interaction/index.js";
import {
  publishPointerEventLog,
  startPointerEventLog,
  stopPointerEventLog,
  type PointerEventLogHandle,
} from "./pointer-events.js";

const execFileAsync = promisify(execFile);

function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Pulls the `detail` field out of the native host's JSON reply, which it writes to stdout even
 * when it exits non-zero.
 */
function hostFailureDetail(error: unknown): string | undefined {
  return hostDetail((error as { stdout?: unknown } | undefined)?.stdout);
}

/** The `detail` of a host JSON reply, such as "Safari cmd+n via=ax menu=\"New Window\"". */
function hostDetail(stdout: unknown): string | undefined {
  if (typeof stdout !== "string" || stdout.trim().length === 0) {
    return undefined;
  }

  try {
    const parsed = JSON.parse(stdout) as { detail?: unknown };
    return typeof parsed.detail === "string" && parsed.detail.length > 0 ? parsed.detail : undefined;
  } catch {
    return undefined;
  }
}

function appSurfaceId(app: TargetApp): string {
  return `surface_${app.bundleId.replace(/[^a-z0-9]+/gi, "_").toLowerCase()}`;
}

function calculatorButtonName(query: TargetQuery): string {
  if (query.semanticId === "calculator.operator.plus") {
    return "Add";
  }

  if (query.semanticId === "calculator.operator.equals") {
    return "Equals";
  }

  return query.text ?? query.semanticId ?? "unknown";
}

function boundsCloseTo(
  current: StageViewport["bounds"],
  target: StageViewport["bounds"],
  tolerance = 6,
): boolean {
  return Math.abs(current.x - target.x) <= tolerance
    && Math.abs(current.y - target.y) <= tolerance
    && Math.abs(current.width - target.width) <= tolerance
    && Math.abs(current.height - target.height) <= tolerance;
}

export function centeredSafeBounds(
  requested: Bounds,
  display: Bounds,
  inset = 72,
): Bounds {
  const values = [
    requested.x,
    requested.y,
    requested.width,
    requested.height,
    display.x,
    display.y,
    display.width,
    display.height,
    inset,
  ];
  if (!values.every(Number.isFinite)) {
    throw new RangeError("Centered viewport geometry must contain finite numbers");
  }
  if (requested.width <= 0 || requested.height <= 0) {
    throw new RangeError("Centered viewport size must be greater than zero");
  }
  if (display.width <= 0 || display.height <= 0) {
    throw new RangeError("Display size must be greater than zero");
  }

  const safeInset = Math.max(0, inset);
  const safeWidth = Math.max(1, display.width - safeInset * 2);
  const safeHeight = Math.max(1, display.height - safeInset * 2);
  const scale = Math.min(1, safeWidth / requested.width, safeHeight / requested.height);
  const width = Math.max(1, Math.round(requested.width * scale));
  const height = Math.max(1, Math.round(requested.height * scale));
  return {
    x: Math.round(display.x + (display.width - width) / 2),
    y: Math.round(display.y + (display.height - height) / 2),
    width,
    height,
  };
}

function containBounds(
  requested: StageViewport["bounds"],
  actual: StageViewport["bounds"],
): StageViewport["bounds"] {
  const corrected = { ...requested };

  if (corrected.x > actual.x) {
    corrected.x = actual.x;
  }

  if (corrected.y > actual.y) {
    corrected.y = actual.y;
  }

  const requestedRight = corrected.x + corrected.width;
  const requestedBottom = corrected.y + corrected.height;
  const actualRight = actual.x + actual.width;
  const actualBottom = actual.y + actual.height;

  if (requestedRight < actualRight) {
    corrected.width = actualRight - corrected.x;
  }

  if (requestedBottom < actualBottom) {
    corrected.height = actualBottom - corrected.y;
  }

  return corrected;
}

interface PixelSize {
  width: number;
  height: number;
}

interface GeometryReport {
  generatedAt: string;
  bundleId?: string;
  surfaceId?: string;
  requestedViewport?: StageViewport["bounds"];
  accessibilityWindowFrame?: StageViewport["bounds"];
  captureWindowFrame?: StageViewport["bounds"];
  resolvedViewport?: StageViewport["bounds"];
  capturePath?: string;
  capturePixelSize?: PixelSize;
  viewportScreenshotPath?: string;
  viewportScreenshotPixelSize?: PixelSize;
  fullScreenshotPath?: string;
  fullScreenshotPixelSize?: PixelSize;
}

interface NativeCurrentSurfaceResponse {
  status: string;
  bundleId: string;
  appName: string;
  frame?: Bounds;
}

export interface CurrentSurfaceSnapshot {
  bundleId: string;
  appName: string;
  surface: SurfaceRef;
}

export interface CurrentSurfaceCaptureResult {
  artifact: RuntimeArtifact;
  currentSurface: CurrentSurfaceSnapshot;
}

export interface CurrentSurfaceAccessibilityResult {
  artifact: RuntimeArtifact;
  currentSurface: CurrentSurfaceSnapshot;
  nodeCount: number;
}

export class MacOSCommandEngine implements SurfaceEngine {
  readonly platform = "macos" as const;

  private readonly surfaces = new Map<string, TargetApp>();
  private activeCapturePath?: string;
  private activeCaptureStopPath?: string;
  private activeCaptureFinishedPath?: string;
  private activePointerEventLog?: PointerEventLogHandle;
  private activeViewport?: StageViewport;
  private focusedSurfaceId?: string;
  private overlayStatePath?: string;
  private overlayStopPath?: string;
  private overlayLogPath?: string;
  private overlayControlPath?: string;
  private overlayActive = false;
  private overlayPid?: number;
  private readonly enableStageControls = process.env.ACTION_STAGE_CONTROLS !== "0";
  private activeBackdrop: BackdropPreset = "neutral";
  private geometryReport: GeometryReport = {
    generatedAt: new Date().toISOString(),
  };
  private geometryReportPath?: string;

  constructor(
    private readonly nativeHostPath = "native/engine/scripts/run-app-host.sh",
  ) {}

  async diagnostics(): Promise<EngineDiagnostics> {
    try {
      const { stdout } = await this.runHost("status");

      return JSON.parse(stdout) as EngineDiagnostics;
    } catch (error) {
      const detail = error instanceof Error ? error.message : "Unknown diagnostics error";

      return {
        accessibility: "unknown",
        screenRecording: "unknown",
        notes: [detail],
      };
    }
  }

  async requestPermissions(): Promise<EngineDiagnostics> {
    const { stdout } = await this.runHost("request");
    return JSON.parse(stdout) as EngineDiagnostics;
  }

  async openPermissionSettings(kind: "accessibility" | "screen-recording"): Promise<void> {
    await this.runHost(
      kind === "accessibility"
        ? "open-accessibility-settings"
        : "open-screen-recording-settings",
    );
  }

  async presentStage(presentation: StagePresentation): Promise<void> {
    const paths = this.ensureOverlayPaths(presentation.sessionId);
    this.overlayStatePath = paths.statePath;
    this.overlayStopPath = paths.stopPath;
    this.overlayLogPath = paths.logPath;
    this.overlayControlPath = this.enableStageControls ? paths.controlPath : undefined;

    await mkdir(dirname(paths.statePath), { recursive: true });
    await rm(paths.stopPath, { force: true });
    await rm(paths.logPath, { force: true });
    if (this.enableStageControls) {
      await rm(paths.controlPath, { force: true });
    }
    await this.writeOverlayState(paths.statePath, presentation);

    if (this.overlayActive) {
      return;
    }

    await this.writeOverlayState(paths.statePath, presentation);

    const { stdout } = await this.runHost(
      "stage-overlay",
      "--state-file",
      paths.statePath,
      "--stop-file",
      paths.stopPath,
      "--debug-log",
      paths.logPath,
      // clearStage is the normal way the drape comes down, but it never runs if this
      // process is killed. The overlay is launched through open(1), so it is not our
      // child and nothing else will take it down. Give it our pid so it can dismiss
      // itself rather than leaving an opaque sheet over the operator's screen.
      "--parent-pid",
      String(process.pid),
      ...(this.enableStageControls ? ["--control-file", paths.controlPath] : []),
    );
    const response = JSON.parse(stdout) as { detail?: string };
    this.overlayPid = response.detail ? Number(response.detail) : undefined;
    this.overlayActive = true;
  }

  async clearStage(): Promise<void> {
    if (this.overlayStopPath) {
      await writeFile(this.overlayStopPath, "stop\n");
      // Give the native overlay timer loop a chance to observe the stop file.
      await new Promise((resolve) => setTimeout(resolve, 220));
    }

    if (this.overlayPid) {
      try {
        await execFileAsync("kill", ["-TERM", String(this.overlayPid)]);
      } catch {}

      await new Promise((resolve) => setTimeout(resolve, 150));

      try {
        process.kill(this.overlayPid, 0);
        await execFileAsync("kill", ["-KILL", String(this.overlayPid)]);
      } catch {}
    } else {
      // Fallback for cases where PID was not captured but an overlay process remains.
      try {
        await execFileAsync("pkill", [
          "-f",
          "/Action.app/Contents/MacOS/Action stage-overlay",
        ]);
      } catch {}
    }

    if (this.overlayStatePath) {
      await rm(this.overlayStatePath, { force: true });
    }

    if (this.overlayStopPath) {
      await rm(this.overlayStopPath, { force: true });
    }

    this.overlayActive = false;
    this.overlayPid = undefined;
    this.overlayLogPath = undefined;
    this.overlayStopPath = undefined;
    this.overlayStatePath = undefined;
    this.overlayControlPath = undefined;
  }

  async setBackdrop(backdrop: BackdropPreset): Promise<void> {
    this.activeBackdrop = backdrop;
  }

  async launchApp(app: TargetApp): Promise<SurfaceRef> {
    await execFileAsync("open", ["-a", app.name]);
    if (app.bundleId === "com.apple.Notes") {
      await new Promise((resolve) => setTimeout(resolve, 450));
      await this.runHost("prepare-notes-note");
      await new Promise((resolve) => setTimeout(resolve, 250));
    }

    const id = appSurfaceId(app);
    this.surfaces.set(id, app);

    return {
      id,
      kind: "window",
      label: `${app.name} Window`,
    };
  }

  async focusSurface(surfaceId: string): Promise<void> {
    const app = this.surfaces.get(surfaceId);

    if (!app) {
      throw new Error(`Unknown surface: ${surfaceId}`);
    }

    await this.runHost("activate-app", "--bundle-id", app.bundleId);
    this.focusedSurfaceId = surfaceId;
  }

  async configureViewport(viewport: StageViewport): Promise<StageViewport> {
    let resolvedViewport = viewport;

    if (viewport.placement === "centered-safe") {
      const selector = {
        x: viewport.bounds.x + viewport.bounds.width / 2,
        y: viewport.bounds.y + viewport.bounds.height / 2,
      };
      const { stdout } = await this.runHost(
        "get-display-frame",
        "--x", String(selector.x),
        "--y", String(selector.y),
      );
      const payload = JSON.parse(stdout) as { frame: Bounds };
      resolvedViewport = {
        ...viewport,
        bounds: centeredSafeBounds(viewport.bounds, payload.frame, viewport.safeAreaInset),
      };
      viewport = resolvedViewport;
    }

    const surfaceId = viewport.surfaceId ?? this.focusedSurfaceId;
    if (!surfaceId) {
      this.activeViewport = resolvedViewport;
      return resolvedViewport;
    }

    const app = this.surfaces.get(surfaceId);
    if (!app) {
      this.activeViewport = resolvedViewport;
      return resolvedViewport;
    }

    this.geometryReport = {
      generatedAt: new Date().toISOString(),
      bundleId: app.bundleId,
      surfaceId,
      requestedViewport: viewport.bounds,
    };

    let frameConfigured = false;
    for (let attempt = 0; attempt < 20; attempt += 1) {
      try {
        await this.runHost(
          "set-window-frame",
          "--bundle-id",
          app.bundleId,
          "--x",
          String(viewport.bounds.x),
          "--y",
          String(viewport.bounds.y),
          "--width",
          String(viewport.bounds.width),
          "--height",
          String(viewport.bounds.height),
        );
        await new Promise((resolve) => setTimeout(resolve, 180));
        const [accessibilityBounds, captureBounds] = await Promise.all([
          this.readAccessibilityWindowBounds(app.bundleId),
          this.readCaptureWindowBounds(app.bundleId),
        ]);
        if (accessibilityBounds) {
          this.geometryReport.accessibilityWindowFrame = accessibilityBounds;
        }
        if (captureBounds) {
          this.geometryReport.captureWindowFrame = captureBounds;
        }

        const actualBounds = captureBounds ?? accessibilityBounds;
        if (actualBounds) {
          const correctedBounds = containBounds(viewport.bounds, actualBounds);
          resolvedViewport = {
            ...viewport,
            bounds: correctedBounds,
            surfaceId,
          };
          frameConfigured = true;
          if (boundsCloseTo(actualBounds, viewport.bounds)) {
            break;
          }
        }
        frameConfigured = true;
      } catch (error) {
        if (attempt === 19) {
          throw error;
        }
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
    }

    if (frameConfigured) {
      const [accessibilityBounds, captureBounds] = await Promise.all([
        this.readAccessibilityWindowBounds(app.bundleId),
        this.readCaptureWindowBounds(app.bundleId),
      ]);
      if (accessibilityBounds) {
        this.geometryReport.accessibilityWindowFrame = accessibilityBounds;
      }
      if (captureBounds) {
        this.geometryReport.captureWindowFrame = captureBounds;
      }
      const actualBounds = captureBounds ?? accessibilityBounds;
      if (actualBounds) {
        resolvedViewport = {
          ...viewport,
          bounds: containBounds(viewport.bounds, actualBounds),
          surfaceId,
        };
      }
    }

    this.geometryReport.generatedAt = new Date().toISOString();
    this.geometryReport.resolvedViewport = resolvedViewport.bounds;
    await this.persistGeometryReport();
    this.activeViewport = resolvedViewport;
    return resolvedViewport;
  }

  async startCapture(request: {
    sessionId?: string;
    outputPath: string;
    viewport?: StageViewport;
    profile?: CaptureProfile;
    clickFeedback?: ClickFeedbackConfig;
  }): Promise<void> {
    const viewport = request.viewport ?? this.activeViewport;
    if (!viewport) {
      throw new Error("No viewport is configured for capture.");
    }

    await mkdir(dirname(request.outputPath), { recursive: true });
    await rm(request.outputPath, { force: true });
    this.activeCapturePath = request.outputPath;
    // Opened before the recorder starts so a click in the first frames is already covered.
    this.activePointerEventLog = await startPointerEventLog({
      runHost: (command, ...args) => this.runHost(command, ...args),
      nativeHostPath: this.nativeHostPath,
      outputPath: request.outputPath,
      recordingId: request.sessionId ?? "capture",
      sessionId: request.sessionId,
      clickFeedback: request.clickFeedback,
    });
    await publishPointerEventLog(this.activePointerEventLog.path);
    this.activeCaptureStopPath = `${request.outputPath}.stop`;
    this.activeCaptureFinishedPath = `${request.outputPath}.finished`;
    this.geometryReportPath = resolve(dirname(request.outputPath), "geometry-report.json");
    this.geometryReport.generatedAt = new Date().toISOString();
    this.geometryReport.capturePath = request.outputPath;
    await this.persistGeometryReport();
    await rm(this.activeCaptureStopPath, { force: true });
    await rm(this.activeCaptureFinishedPath, { force: true });
    const app = viewport.surfaceId ? this.surfaces.get(viewport.surfaceId) : undefined;
    if (app) {
      await this.startWindowRecordingSession(
        app.bundleId,
        request.outputPath,
        this.activeCaptureStopPath,
        this.activeCaptureFinishedPath,
      );
      return;
    }

    await this.startRecordingSession(
      viewport,
      request.outputPath,
      this.activeCaptureStopPath,
      this.activeCaptureFinishedPath,
      request.profile ?? "draft",
    );
  }

  async pauseCapture(): Promise<void> {}

  async resumeCapture(): Promise<void> {}

  async stopCapture(): Promise<RuntimeArtifact> {
    const path = this.activeCapturePath ?? resolve(process.cwd(), "artifacts", "sessions", "macos", "capture.mov");
    const stopPath = this.activeCaptureStopPath;
    const finishedPath = this.activeCaptureFinishedPath;
    const pointerEventLog = this.activePointerEventLog;

    // Clicks after this point belong to no recording, and the pulse overlay has nothing left to
    // show. Both are torn down before the placeholder branch so neither leaks past a failed run.
    if (pointerEventLog) {
      await stopPointerEventLog(pointerEventLog);
      await publishPointerEventLog(undefined);
      this.activePointerEventLog = undefined;
    }

    if (!stopPath) {
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, "");

      return {
        kind: "raw-capture",
        path,
        metadata: {
          placeholder: true,
          reason: "Capture process was not active.",
        },
      };
    }

    await writeFile(stopPath, "stop\n");
    await this.waitForCaptureCompletion(path, finishedPath);
    await rm(stopPath, { force: true });
    if (finishedPath) {
      await rm(finishedPath, { force: true });
    }
    this.activeCaptureStopPath = undefined;
    this.activeCaptureFinishedPath = undefined;
    const capturePixelSize = await this.readVideoPixelSize(path);
    if (capturePixelSize) {
      this.geometryReport.generatedAt = new Date().toISOString();
      this.geometryReport.capturePixelSize = capturePixelSize;
      await this.persistGeometryReport();
    }

    return {
      kind: "raw-capture",
      path,
      metadata: pointerEventLog
        ? {
            pointerEventLog: pointerEventLog.path,
            clickFeedback: pointerEventLog.feedbackEnabled,
          }
        : undefined,
    };
  }

  async captureScreenshot(path: string): Promise<RuntimeArtifact> {
    const viewport = this.activeViewport;
    if (!viewport) {
      throw new Error("No viewport is configured for screenshot capture.");
    }

    await mkdir(dirname(path), { recursive: true });
    await rm(path, { force: true });
    if (this.activeCapturePath && !this.activeCaptureStopPath) {
      try {
        await this.extractFrameFromCapture(this.activeCapturePath, path);
        if (this.activeBackdrop === "matte") {
          await this.composeMatteViewport(path);
        }
        await this.waitForFile(path, 1);
        await this.recordScreenshotDimensions(path, "viewport");

        return {
          kind: "screenshot",
          path,
          metadata: {
            source: "capture-frame",
          },
        };
      } catch {}
    }

    const app = viewport.surfaceId ? this.surfaces.get(viewport.surfaceId) : undefined;
    if (app) {
      await this.runHost(
        "screenshot-app-window",
        "--bundle-id",
        app.bundleId,
        "--output",
        path,
      );
      await this.waitForFile(path, 1);
      await this.recordScreenshotDimensions(path, "viewport");

      return {
        kind: "screenshot",
        path,
      };
    }

    await this.runHost(
      "screenshot-region",
      "--x",
      String(viewport.bounds.x),
      "--y",
      String(viewport.bounds.y),
      "--width",
      String(viewport.bounds.width),
      "--height",
      String(viewport.bounds.height),
      "--output",
      path,
    );
    await this.waitForFile(path, 1);
    await this.recordScreenshotDimensions(path, "viewport");

    return {
      kind: "screenshot",
      path,
    };
  }

  async captureFullScreenshot(path: string): Promise<RuntimeArtifact> {
    await mkdir(dirname(path), { recursive: true });
    await rm(path, { force: true });
    await this.runHost(
      "screenshot-screen",
      "--output",
      path,
    );
    await this.waitForFile(path, 1);
    await this.recordScreenshotDimensions(path, "full");

    return {
      kind: "screenshot",
      path,
      metadata: {
        scope: "full-screen",
      },
    };
  }

  async consumeStageControls(): Promise<string[]> {
    const controlPath = this.overlayControlPath;
    if (!controlPath) {
      return [];
    }

    try {
      const raw = await readFile(controlPath, "utf8");
      const commands = raw
        .split(/\r?\n/g)
        .map((line) => line.trim().toLowerCase())
        .filter(Boolean);
      if (commands.length > 0) {
        await writeFile(controlPath, "");
      }
      return commands;
    } catch {
      return [];
    }
  }

  /**
   * Echoes the query back in ResolvedTarget shape. This engine performs no semantic lookup of its
   * own — an accessibility search happens later, inside the action, against the app that is
   * actually frontmost — so the only thing genuinely resolved here is a point the caller supplied.
   *
   * Confidence says exactly that and nothing more: a supplied point is the point, so 1; a label
   * that has been matched against nothing is not resolution, so 0. Reporting a plausible-looking
   * number for the second case would tell callers a lookup succeeded when none was attempted.
   */
  async resolveTarget(query: TargetQuery): Promise<ResolvedTarget> {
    const surfaceId = query.surfaceId ?? this.focusedSurfaceId;
    return {
      id: query.semanticId ?? query.text ?? "target",
      point: query.point ? { ...query.point } : undefined,
      mode: query.point ? "coordinate" : "semantic",
      confidence: query.point ? 1 : 0,
      label: query.semanticId ?? query.text ?? "Resolved Target",
      surfaceId,
    };
  }

  /**
   * Pass `agentLayer` when an agent layer is up: coordinate clicks on it and keyboard acts
   * then run as blink acts (see `blinkRouteFor`). Resolves to the host's detail for the
   * last command it ran, which says how the act landed (`via=ax`, `via=keys`, ...).
   * `onDispatch` runs before each host command, so a caller can tell a throw that
   * left the app untouched from one that followed a command.
   */
  async performAction(
    action: RuntimeAction,
    target?: ResolvedTarget,
    options: { agentLayer?: AgentLayerRouting; onDispatch?: () => void } = {},
  ): Promise<string | undefined> {
    const context = this.interactionContext(options.agentLayer);
    let detail: string | undefined;
    await executeInteractionAction(action, target, {
      ...context,
      runHost: async (command, ...args) => {
        options.onDispatch?.();
        const reply = await context.runHost(command, ...args);
        detail = hostDetail(reply.stdout) ?? detail;
        return reply;
      },
    });
    return detail;
  }

  /** The blink command `performAction` would use for this act, if any. Drives tier inference. */
  blinkRoute(
    action: RuntimeAction,
    target: ResolvedTarget | undefined,
    agentLayer: AgentLayerRouting | undefined,
  ): BlinkRoute | undefined {
    return blinkRouteFor(action, target, this.interactionContext(agentLayer));
  }

  private interactionContext(agentLayer: AgentLayerRouting | undefined): InteractionExecutionContext {
    return {
      runHost: this.runHost.bind(this),
      resolveCalculatorButton: (query) => calculatorButtonName(query),
      resolveBundleId: (surfaceId) => {
        const resolvedSurfaceId = surfaceId ?? this.focusedSurfaceId;
        if (!resolvedSurfaceId) {
          return undefined;
        }
        return this.surfaces.get(resolvedSurfaceId)?.bundleId;
      },
      ...(agentLayer ? { agentLayer } : {}),
    };
  }

  async replayArtifact(path: string): Promise<void> {
    await execFileAsync("open", [path]);
  }

  async currentSurface(): Promise<CurrentSurfaceSnapshot> {
    const { stdout } = await this.runHost("current-surface");
    const response = JSON.parse(stdout) as NativeCurrentSurfaceResponse;
    const targetApp = {
      name: response.appName,
      bundleId: response.bundleId,
    };
    const surface: SurfaceRef = {
      id: appSurfaceId(targetApp),
      kind: "window",
      label: `${response.appName} Window`,
      bounds: response.frame,
    };

    this.surfaces.set(surface.id, targetApp);
    this.focusedSurfaceId = surface.id;

    return {
      bundleId: response.bundleId,
      appName: response.appName,
      surface,
    };
  }

  async captureCurrentSurfaceScreenshot(path: string): Promise<CurrentSurfaceCaptureResult> {
    const currentSurface = await this.currentSurface();
    const artifact = await this.captureSurfaceScreenshot(currentSurface, path);

    return {
      artifact,
      currentSurface,
    };
  }

  async captureSurfaceScreenshot(
    currentSurface: CurrentSurfaceSnapshot,
    path: string,
  ): Promise<RuntimeArtifact> {
    await mkdir(dirname(path), { recursive: true });
    await rm(path, { force: true });
    await this.runHost(
      "screenshot-app-window",
      "--bundle-id",
      currentSurface.bundleId,
      "--output",
      path,
    );
    await this.waitForFile(path, 1);

    return {
      kind: "screenshot",
      path,
      metadata: {
        bundleId: currentSurface.bundleId,
        surfaceId: currentSurface.surface.id,
        scope: "current-surface",
      },
    };
  }

  async captureCurrentSurfaceAccessibilitySnapshot(path: string): Promise<CurrentSurfaceAccessibilityResult> {
    const currentSurface = await this.currentSurface();
    const { artifact, nodeCount } = await this.captureSurfaceAccessibilitySnapshot(currentSurface, path);

    return {
      artifact,
      currentSurface,
      nodeCount,
    };
  }

  async captureSurfaceAccessibilitySnapshot(
    currentSurface: CurrentSurfaceSnapshot,
    path: string,
  ): Promise<{ artifact: RuntimeArtifact; nodeCount: number }> {
    await mkdir(dirname(path), { recursive: true });
    await rm(path, { force: true });
    const { stdout } = await this.runHost(
      "inspect-app-ui",
      "--bundle-id",
      currentSurface.bundleId,
    );
    const nodes = JSON.parse(stdout) as unknown[];
    await writeFile(path, JSON.stringify(nodes, null, 2));

    return {
      artifact: {
        kind: "ax-snapshot",
        path,
        metadata: {
          bundleId: currentSurface.bundleId,
          surfaceId: currentSurface.surface.id,
          scope: "current-surface",
          nodeCount: nodes.length,
        },
      },
      nodeCount: nodes.length,
    };
  }

  async setWindowFrame(bundleId: string, bounds: Bounds): Promise<void> {
    await this.runHost(
      "set-window-frame",
      "--bundle-id",
      bundleId,
      "--x",
      String(bounds.x),
      "--y",
      String(bounds.y),
      "--width",
      String(bounds.width),
      "--height",
      String(bounds.height),
    )
  }

  async readWindowBounds(bundleId: string): Promise<Bounds | undefined> {
    const [accessibilityBounds, captureBounds] = await Promise.all([
      this.readAccessibilityWindowBounds(bundleId),
      this.readCaptureWindowBounds(bundleId),
    ])
    return captureBounds ?? accessibilityBounds
  }

  async dragMouse(from: Point, to: Point, durationMs = 300): Promise<void> {
    await this.runHost(
      "drag",
      "--from-x",
      String(from.x),
      "--from-y",
      String(from.y),
      "--to-x",
      String(to.x),
      "--to-y",
      String(to.y),
      "--duration-ms",
      String(durationMs),
    )
  }

  private async runHost(command: string, ...args: string[]) {
    try {
      return await execFileAsync(this.nativeHostPath, [command, ...args]);
    } catch (error) {
      // The host reports why it failed in the JSON reply on stdout; execFile's own message is
      // just the command line, so surface the host's detail or the caller cannot act on it.
      throw new Error(`${command} failed: ${hostFailureDetail(error) ?? describeError(error)}`, {
        cause: error,
      });
    }
  }

  private async startRecordingSession(
    viewport: StageViewport,
    outputPath: string,
    stopPath: string,
    finishedPath: string,
    profile: CaptureProfile,
  ): Promise<void> {
    const fps = profile === "draft" ? "15" : "60";
    const scale = profile === "draft" ? "0.75" : "1";

    await this.runHost(
      "record-region",
      "--x",
      String(viewport.bounds.x),
      "--y",
      String(viewport.bounds.y),
      "--width",
      String(viewport.bounds.width),
      "--height",
      String(viewport.bounds.height),
      "--fps",
      fps,
      "--scale",
      scale,
      "--output",
      outputPath,
      "--stop-file",
      stopPath,
      "--finished-file",
      finishedPath,
    );
  }

  private async startWindowRecordingSession(
    bundleId: string,
    outputPath: string,
    stopPath: string,
    finishedPath: string,
  ): Promise<void> {
    await this.runHost(
      "record-app-window",
      "--bundle-id",
      bundleId,
      "--output",
      outputPath,
      "--stop-file",
      stopPath,
      "--finished-file",
      finishedPath,
    );
  }

  private async waitForCaptureCompletion(path: string, finishedPath?: string): Promise<void> {
    if (finishedPath) {
      await this.waitForFile(finishedPath, 1);
      const status = (await readFile(finishedPath, "utf8")).trim();
      if (status.startsWith("error:")) {
        throw new Error(`Native capture failed: ${status.slice("error:".length).trim()}`);
      }
    }

    await this.waitForFile(path, 1);
  }

  private async waitForFile(path: string, minBytes: number): Promise<void> {
    for (let attempt = 0; attempt < 100; attempt += 1) {
      try {
        await access(path);
        const file = await stat(path);
        if (file.size >= minBytes) {
          return;
        }
      } catch {}

      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    throw new Error(`Timed out waiting for file ${path}`);
  }

  private ensureOverlayPaths(sessionId: string) {
    const root = resolve(process.cwd(), "artifacts", "overlays", sessionId);
    return {
      statePath: resolve(root, "stage.json"),
      stopPath: resolve(root, "stage.stop"),
      logPath: resolve(root, "stage.log"),
      controlPath: resolve(root, "stage.controls"),
    };
  }

  private async writeOverlayState(path: string, presentation: StagePresentation): Promise<void> {
    const tempPath = `${path}.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}.tmp`;
    await writeFile(tempPath, `${JSON.stringify(presentation, null, 2)}\n`);
    await rename(tempPath, path);
  }

  private async readCaptureWindowBounds(bundleId: string): Promise<StageViewport["bounds"] | undefined> {
    try {
      const { stdout } = await this.runHost(
        "get-capture-window-frame",
        "--bundle-id",
        bundleId,
      );
      const payload = JSON.parse(stdout) as {
        frame?: StageViewport["bounds"];
      };
      return payload.frame;
    } catch {
      try {
        const { stdout } = await this.runHost(
          "get-window-frame",
          "--bundle-id",
          bundleId,
        );
        const payload = JSON.parse(stdout) as {
          frame?: StageViewport["bounds"];
        };
        return payload.frame;
      } catch {
        return undefined;
      }
    }
  }

  private async readAccessibilityWindowBounds(bundleId: string): Promise<StageViewport["bounds"] | undefined> {
    try {
      const { stdout } = await this.runHost(
        "get-window-frame",
        "--bundle-id",
        bundleId,
      );
      const payload = JSON.parse(stdout) as {
        frame?: StageViewport["bounds"];
      };
      return payload.frame;
    } catch {
      return undefined;
    }
  }

  private async extractFrameFromCapture(capturePath: string, outputPath: string): Promise<void> {
    await execFileAsync("ffmpeg", [
      "-y",
      "-sseof",
      "-0.2",
      "-i",
      capturePath,
      "-frames:v",
      "1",
      outputPath,
    ]);
  }

  private async composeMatteViewport(path: string): Promise<void> {
    await this.runHost(
      "compose-rounded-screenshot",
      "--input",
      path,
      "--output",
      path,
      "--radius",
      "24",
      "--background",
      "E8EDF5",
    );
  }

  private async persistGeometryReport(): Promise<void> {
    if (!this.geometryReportPath) {
      return;
    }

    await mkdir(dirname(this.geometryReportPath), { recursive: true });
    const tempPath = `${this.geometryReportPath}.${process.pid}.${Date.now()}.tmp`;
    await writeFile(tempPath, `${JSON.stringify(this.geometryReport, null, 2)}\n`);
    await rename(tempPath, this.geometryReportPath);
  }

  private async readVideoPixelSize(path: string): Promise<PixelSize | undefined> {
    try {
      const { stdout } = await execFileAsync("ffprobe", [
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height",
        "-of",
        "json",
        path,
      ]);
      const payload = JSON.parse(stdout) as {
        streams?: Array<{ width?: number; height?: number }>;
      };
      const stream = payload.streams?.[0];
      if (!stream?.width || !stream?.height) {
        return undefined;
      }
      return {
        width: stream.width,
        height: stream.height,
      };
    } catch {
      return undefined;
    }
  }

  private async readImagePixelSize(path: string): Promise<PixelSize | undefined> {
    try {
      const { stdout } = await execFileAsync("sips", [
        "-g",
        "pixelWidth",
        "-g",
        "pixelHeight",
        path,
      ]);
      const widthMatch = stdout.match(/pixelWidth:\s+(\d+)/);
      const heightMatch = stdout.match(/pixelHeight:\s+(\d+)/);
      if (!widthMatch || !heightMatch) {
        return undefined;
      }
      return {
        width: Number(widthMatch[1]),
        height: Number(heightMatch[1]),
      };
    } catch {
      return undefined;
    }
  }

  private async recordScreenshotDimensions(path: string, scope: "viewport" | "full"): Promise<void> {
    const pixelSize = await this.readImagePixelSize(path);
    if (!pixelSize) {
      return;
    }

    this.geometryReport.generatedAt = new Date().toISOString();
    if (scope === "viewport") {
      this.geometryReport.viewportScreenshotPath = path;
      this.geometryReport.viewportScreenshotPixelSize = pixelSize;
    } else {
      this.geometryReport.fullScreenshotPath = path;
      this.geometryReport.fullScreenshotPixelSize = pixelSize;
    }
    await this.persistGeometryReport();
  }
}
