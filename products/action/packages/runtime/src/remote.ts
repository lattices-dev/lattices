import { mkdir, writeFile } from "node:fs/promises";
import { dirname, extname } from "node:path";
import { pairingHeaders } from "../../../../../bin/host-pairing.js";
import type {
  BackdropPreset,
  Bounds,
  CaptureStartRequest,
  EngineDiagnostics,
  ResolvedTarget,
  RuntimeAction,
  RuntimeArtifact,
  StagePresentation,
  StageViewport,
  SurfaceRef,
  TargetApp,
  TargetQuery,
} from "@action/protocol";
import { clickPoint, dragPoints, scrollPoint } from "./interaction/index.js";
import { parseKeyChord, type KeyModifier } from "./interaction/keys.js";
import type { CurrentSurfaceCaptureResult, CurrentSurfaceSnapshot } from "./macos.js";
import type { SurfaceEngine } from "./surface-engine.js";
import type { OCRResult } from "./vision.js";

/**
 * Drives a remote lattices host (LAT-013), such as a Linux machine running
 * `lattices-host`, through the daemon protocol over a WebSocket. Runs, traces
 * and artifacts stay local: screenshots and recordings are fetched back and
 * written where the session asked for them.
 *
 * What macOS has and the host does not is absent rather than faked: there is
 * no accessibility tree, the stage and backdrop are no-ops, and targets
 * resolve by point or by OCR text.
 */

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonObject = { [key: string]: Json };

interface HostWindow {
  wid: number;
  app: string;
  title: string;
  frame: { x: number; y: number; w: number; h: number };
  isFocused: boolean;
  displayIndex: number;
}

interface HostDisplay {
  displayIndex: number;
  frame: { x: number; y: number; w: number; h: number };
  visibleFrame: { x: number; y: number; w: number; h: number };
}

export interface RemoteEngineOptions {
  /** Host name or address, e.g. `archie` or `100.119.71.19`. */
  host: string;
  port?: number;
  /** Per-call timeout. Recording stop and downloads use longer ones. */
  timeoutMs?: number;
  /** Frames per second for remote recordings (1-15). */
  recordFps?: number;
}

export class RemoteHostClient {
  private socket: WebSocket | null = null;
  private opening: Promise<WebSocket> | null = null;
  private nextId = 1;
  private pending = new Map<string, { resolve: (v: Json) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>();

  constructor(readonly url: string, private readonly timeoutMs = 15_000) {}

  private open(): Promise<WebSocket> {
    if (this.socket?.readyState === WebSocket.OPEN) return Promise.resolve(this.socket);
    this.opening ??= new Promise<WebSocket>((resolve, reject) => {
      const endpoint = new URL(this.url);
      const headers = Object.fromEntries(pairingHeaders(
        { host: endpoint.hostname, port: Number(endpoint.port || 9399) }, endpoint.pathname
      ).map((line) => line.split(": ", 2)));
      // Action runs in Bun, whose WebSocket constructor accepts upgrade headers.
      const Client = WebSocket as unknown as new (url: string, options: { headers: Record<string, string> }) => WebSocket;
      const socket = new Client(this.url, { headers });
      socket.onopen = () => {
        this.socket = socket;
        this.opening = null;
        resolve(socket);
      };
      socket.onerror = () => {
        this.opening = null;
        reject(new Error(`Cannot reach lattices host at ${this.url}`));
      };
      socket.onclose = () => {
        this.socket = null;
        for (const [id, call] of this.pending) {
          clearTimeout(call.timer);
          call.reject(new Error("lattices host connection closed"));
          this.pending.delete(id);
        }
      };
      socket.onmessage = (message) => {
        let frame: { id?: string; result?: Json; error?: string | null };
        try {
          frame = JSON.parse(String(message.data));
        } catch {
          return;
        }
        if (!frame.id) return; // events
        const call = this.pending.get(frame.id);
        if (!call) return;
        this.pending.delete(frame.id);
        clearTimeout(call.timer);
        if (frame.error) call.reject(new Error(frame.error));
        else call.resolve(frame.result ?? null);
      };
    });
    return this.opening;
  }

  async call<T = Json>(method: string, params: JsonObject = {}, timeoutMs = this.timeoutMs): Promise<T> {
    const socket = await this.open();
    const id = `r${this.nextId++}`;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, { resolve: resolve as (v: Json) => void, reject, timer });
      socket.send(JSON.stringify({ id, method, params, deadline: Date.now() + timeoutMs }));
    });
  }

  close() {
    this.socket?.close();
    this.socket = null;
  }
}

const MODIFIER_NAMES: Record<KeyModifier, string> = { cmd: "command", shift: "shift", opt: "option", ctrl: "control" };

const surfaceIdFor = (wid: number) => `remote:wid:${wid}`;
const widFromSurfaceId = (surfaceId: string | undefined) => {
  const match = /^remote:wid:(\d+)$/.exec(surfaceId ?? "");
  return match ? Number(match[1]) : undefined;
};
const toBounds = (f: { x: number; y: number; w: number; h: number }): Bounds => ({ x: f.x, y: f.y, width: f.w, height: f.h });
const toRegion = (b: Bounds) => ({ x: b.x, y: b.y, width: b.width, height: b.height });

export class RemoteEngine implements SurfaceEngine {
  readonly platform = "remote" as const;
  readonly client: RemoteHostClient;
  private focusedSurfaceId: string | undefined;
  private activeViewport: StageViewport | undefined;
  private activeCapturePath: string | undefined;
  private readonly recordFps: number;

  constructor(readonly options: RemoteEngineOptions) {
    const url = `ws://${options.host}:${options.port ?? 9399}`;
    this.client = new RemoteHostClient(url, options.timeoutMs);
    this.recordFps = options.recordFps ?? 5;
  }

  async diagnostics(): Promise<EngineDiagnostics> {
    try {
      const describe = await this.client.call<{ platform: string; hostname: string; tailnetName?: string | null; capabilities: string[] }>("host.describe");
      const caps = new Set(describe.capabilities);
      return {
        accessibility: caps.has("input.pointer") && caps.has("input.keys") ? "granted" : "denied",
        screenRecording: caps.has("capture.still") ? "granted" : "denied",
        platform: describe.platform,
        host: describe.tailnetName ?? describe.hostname,
        capabilities: describe.capabilities,
        notes: [
          `remote lattices host ${this.client.url} (${describe.platform})`,
          "accessibility maps to input.pointer + input.keys; screenRecording to capture.still",
        ],
      };
    } catch (error) {
      return {
        accessibility: "unknown",
        screenRecording: "unknown",
        notes: [error instanceof Error ? error.message : String(error)],
      };
    }
  }

  async requestPermissions(): Promise<EngineDiagnostics> {
    return this.diagnostics();
  }

  async openPermissionSettings(): Promise<void> {
    throw new Error("Permissions on a remote host are its own tools (grim, wtype, the virtual pointer); there is no settings pane to open.");
  }

  // The stage, backdrop and drape are macOS overlays drawn by Action.app.
  async presentStage(_presentation: StagePresentation): Promise<void> {}
  async clearStage(): Promise<void> {}
  async setBackdrop(_backdrop: BackdropPreset): Promise<void> {}

  async launchApp(app: TargetApp): Promise<SurfaceRef> {
    // A reverse-DNS bundle id means nothing on Linux; a plain one is a command.
    const command = app.bundleId && !app.bundleId.includes(".") ? app.bundleId : app.name.toLowerCase();
    const result = await this.client.call<{ window: HostWindow | null }>("apps.open", { command }, 20_000);
    if (!result.window) throw new Error(`${command} opened no window on the remote host`);
    return this.surfaceFor(result.window);
  }

  async focusSurface(surfaceId: string): Promise<void> {
    const wid = widFromSurfaceId(surfaceId);
    if (wid === undefined) throw new Error(`Unknown surface: ${surfaceId}`);
    await this.client.call("windows.focus", { wid });
    this.focusedSurfaceId = surfaceId;
  }

  async configureViewport(viewport: StageViewport): Promise<StageViewport> {
    const displays = await this.client.call<HostDisplay[]>("spaces.list");
    const display = displays[0];
    if (!display) throw new Error("Remote host reports no displays");
    const visible = display.visibleFrame;
    let bounds = viewport.bounds;
    if (viewport.placement === "centered-safe") {
      const inset = viewport.safeAreaInset ?? 72;
      const width = Math.min(bounds.width, visible.w - 2 * inset);
      const height = Math.min(bounds.height, visible.h - 2 * inset);
      bounds = { x: visible.x + (visible.w - width) / 2, y: visible.y + (visible.h - height) / 2, width, height };
    }
    const wid = widFromSurfaceId(viewport.surfaceId ?? this.focusedSurfaceId);
    if (wid !== undefined) {
      const placement = {
        kind: "fractions",
        x: (bounds.x - visible.x) / visible.w,
        y: (bounds.y - visible.y) / visible.h,
        w: bounds.width / visible.w,
        h: bounds.height / visible.h,
      };
      const receipt = await this.client.call<{ after?: { x: number; y: number; w: number; h: number } | null }>("windows.place", {
        wid,
        placement,
        display: display.displayIndex,
      });
      if (receipt.after) bounds = toBounds(receipt.after);
    }
    this.activeViewport = { ...viewport, bounds };
    return this.activeViewport;
  }

  async startCapture(request: CaptureStartRequest): Promise<void> {
    const viewport = request.viewport ?? this.activeViewport;
    await this.client.call("capture.record", {
      action: "start",
      ...(viewport ? toRegion(viewport.bounds) : { displayIndex: 0 }),
      fps: this.recordFps,
      format: extname(request.outputPath).toLowerCase() === ".mov" ? "mov" : "mp4",
    });
    this.activeCapturePath = request.outputPath;
  }

  async pauseCapture(): Promise<void> {
    await this.client.call("capture.record", { action: "pause" });
  }

  async resumeCapture(): Promise<void> {
    await this.client.call("capture.record", { action: "resume" });
  }

  async stopCapture(): Promise<RuntimeArtifact> {
    const path = this.activeCapturePath;
    if (!path) throw new Error("No remote capture is running");
    const stopped = await this.client.call<{ path: string; frames: number; fps: number; seconds: number }>(
      "capture.record",
      { action: "stop" },
      300_000
    );
    await this.download(stopped.path, path);
    this.activeCapturePath = undefined;
    return {
      kind: "raw-capture",
      path,
      metadata: { remote: this.client.url, remotePath: stopped.path, frames: stopped.frames, fps: stopped.fps, durationSeconds: stopped.seconds },
    };
  }

  async captureScreenshot(path: string): Promise<RuntimeArtifact> {
    const viewport = this.activeViewport;
    if (viewport) return this.writeCapture("capture.screenshotRegion", toRegion(viewport.bounds), path, "viewport");
    const surface = await this.currentSurface();
    return this.captureSurfaceScreenshot(surface, path);
  }

  async captureFullScreenshot(path: string): Promise<RuntimeArtifact> {
    return this.writeCapture("capture.screenshotDisplay", { displayIndex: 0 }, path, "display");
  }

  async consumeStageControls(): Promise<string[]> {
    return [];
  }

  /**
   * A supplied point is the point (confidence 1). Text is looked up with OCR
   * on the remote screen, inside the target surface when one is known, and
   * resolves to the center of the best matching line.
   */
  async resolveTarget(query: TargetQuery): Promise<ResolvedTarget> {
    const surfaceId = query.surfaceId ?? this.focusedSurfaceId;
    if (query.point) {
      return { id: query.semanticId ?? query.text ?? "point", point: { ...query.point }, mode: "coordinate", confidence: 1, label: query.text ?? "point", surfaceId };
    }
    const text = query.text ?? query.semanticId;
    if (text) {
      const wid = widFromSurfaceId(surfaceId);
      const found = await this.client.call<{ matches: { text: string; confidence: number; bounds: { x: number; y: number; w: number; h: number }; point: { x: number; y: number } }[] }>(
        "ocr.find",
        wid !== undefined ? { text, wid } : { text, displayIndex: 0 },
        45_000
      );
      const [best, ...rest] = found.matches;
      if (best) {
        return {
          id: query.semanticId ?? text,
          point: best.point,
          bounds: toBounds(best.bounds),
          mode: "textual",
          confidence: best.confidence,
          label: best.text,
          surfaceId,
          ...(rest.length > 0 ? { ambiguousWith: rest.slice(0, 5).map((m) => m.text) } : {}),
        };
      }
    }
    return { id: query.semanticId ?? query.text ?? "target", mode: "semantic", confidence: 0, label: query.semanticId ?? query.text ?? "Resolved Target", surfaceId };
  }

  async performAction(action: RuntimeAction, target?: ResolvedTarget, _options?: unknown): Promise<string | undefined> {
    const execute = { treatment: "execute" } as const;
    switch (action.kind) {
      case "click": {
        let point = clickPoint(action, target);
        if (!point && (target?.label || action.target?.text)) {
          const resolved = await this.resolveTarget(action.target ?? { text: target?.label });
          point = resolved.point;
        }
        if (!point) throw new Error("Click on a remote host needs a point or text it can find on screen");
        const count = typeof action.input?.count === "number" ? action.input.count : 1;
        const button = action.input?.button === "right" ? "right" : "left";
        await this.client.call("computer.click", { x: point.x, y: point.y, count, button, ...execute });
        return "via=remote-pointer";
      }
      case "type": {
        await this.client.call("computer.typeText", { text: String(action.input?.text ?? ""), ...execute });
        return "via=remote-keys";
      }
      case "press-key": {
        const { key, modifiers } = parseKeyChord(action.input ?? {});
        await this.client.call("computer.pressKey", { key, modifiers: modifiers.map((m) => MODIFIER_NAMES[m]), ...execute });
        return "via=remote-keys";
      }
      case "focus-window": {
        const wid = widFromSurfaceId(target?.surfaceId ?? action.target?.surfaceId);
        if (wid !== undefined) {
          await this.client.call("windows.focus", { wid });
        } else {
          const title = typeof action.input?.windowTitle === "string" ? action.input.windowTitle : undefined;
          const app = typeof action.input?.bundleId === "string" ? action.input.bundleId : undefined;
          if (!title && !app) throw new Error("focus-window on a remote host needs a surface, windowTitle or app");
          const window = await this.findWindow(title ?? app!);
          await this.client.call("windows.focus", { wid: window.wid });
          this.focusedSurfaceId = surfaceIdFor(window.wid);
        }
        return "via=remote-focus";
      }
      case "open-app": {
        const name = String(action.input?.app ?? action.input?.name ?? action.input?.bundleId ?? "");
        if (!name) throw new Error("open-app needs input.app, input.name or input.bundleId");
        const surface = await this.launchApp({ name, bundleId: String(action.input?.bundleId ?? "") });
        this.focusedSurfaceId = surface.id;
        return "via=remote-exec";
      }
      case "drag": {
        const points = dragPoints(action, target);
        if (!points) throw new Error("Drag action requires both from and to points");
        await this.client.call("computer.drag", { fromX: points.from.x, fromY: points.from.y, toX: points.to.x, toY: points.to.y, ...execute });
        return "via=remote-pointer";
      }
      case "scroll": {
        const point = scrollPoint(action, target);
        const dx = Number(action.input?.deltaX ?? 0);
        const dy = Number(action.input?.deltaY ?? 0);
        if (dx === 0 && dy === 0) throw new Error("Scroll action requires a non-zero deltaX or deltaY");
        await this.client.call("computer.scroll", { ...(point ? { x: point.x, y: point.y } : {}), dx, dy, ...execute });
        return "via=remote-pointer";
      }
      case "start-recording": {
        const outputPath = String(action.input?.outputPath ?? "");
        if (!outputPath) throw new Error("start-recording needs input.outputPath");
        await this.startCapture({ sessionId: action.id, outputPath });
        return "via=remote-record";
      }
      case "stop-recording":
        await this.stopCapture();
        return "via=remote-record";
      case "show-cue":
        return "via=remote-noop";
      case "wait-for-condition": {
        const ms = Number(action.input?.timeoutMs ?? action.input?.durationMs ?? 0);
        if (ms > 0) await new Promise((r) => setTimeout(r, Math.min(ms, 60_000)));
        return "via=remote-wait";
      }
    }
  }

  async replayArtifact(path: string): Promise<void> {
    throw new Error(`Open ${path} locally; the remote engine does not play media.`);
  }

  async currentSurface(): Promise<CurrentSurfaceSnapshot> {
    const windows = await this.client.call<HostWindow[]>("windows.list");
    const window = windows.find((w) => w.isFocused) ?? windows[0];
    if (!window) throw new Error("Remote host has no windows");
    const surface = this.surfaceFor(window);
    this.focusedSurfaceId = surface.id;
    return { bundleId: window.app, appName: window.app, surface };
  }

  async captureCurrentSurfaceScreenshot(path: string): Promise<CurrentSurfaceCaptureResult> {
    const currentSurface = await this.currentSurface();
    return { artifact: await this.captureSurfaceScreenshot(currentSurface, path), currentSurface };
  }

  async captureSurfaceScreenshot(currentSurface: CurrentSurfaceSnapshot, path: string): Promise<RuntimeArtifact> {
    const wid = widFromSurfaceId(currentSurface.surface.id);
    return this.writeCapture("capture.screenshotWindow", wid !== undefined ? { wid } : {}, path, "surface");
  }

  /** OCR runs on the host, where the pixels are. Boxes are in image pixels, like the native OCR. */
  async ocrSurface(
    currentSurface: CurrentSurfaceSnapshot,
    imagePath: string,
    outputPath: string,
  ): Promise<{ artifact: RuntimeArtifact; result: OCRResult }> {
    const wid = widFromSurfaceId(currentSurface.surface.id);
    const read = await this.client.call<{
      imageWidth: number;
      imageHeight: number;
      fullText: string;
      blockCount: number;
      blocks: { text: string; confidence: number; frame: { x: number; y: number; width: number; height: number } }[];
    }>("ocr.read", wid !== undefined ? { wid } : { displayIndex: 0 }, 45_000);
    const result: OCRResult = {
      imagePath,
      imageWidth: read.imageWidth,
      imageHeight: read.imageHeight,
      blockCount: read.blockCount,
      fullText: read.fullText,
      blocks: read.blocks.map((b) => ({ text: b.text, confidence: b.confidence, frame: b.frame })),
    };
    await mkdir(dirname(outputPath), { recursive: true });
    await writeFile(outputPath, JSON.stringify(result, null, 2));
    return {
      result,
      artifact: { kind: "ocr-snapshot", path: outputPath, metadata: { imagePath, blockCount: result.blockCount, imageWidth: result.imageWidth, imageHeight: result.imageHeight, engine: "tesseract", remote: this.client.url } },
    };
  }

  close() {
    this.client.close();
  }

  private surfaceFor(window: HostWindow): SurfaceRef {
    return { id: surfaceIdFor(window.wid), kind: "window", label: `${window.app} — ${window.title}`, bounds: toBounds(window.frame) };
  }

  private async findWindow(query: string): Promise<HostWindow> {
    const hits = await this.client.call<HostWindow[]>("windows.search", { query, limit: 1 });
    if (!hits[0]) throw new Error(`No remote window matches ${query}`);
    return hits[0];
  }

  private async writeCapture(method: string, params: JsonObject, path: string, scope: string): Promise<RuntimeArtifact> {
    const shot = await this.client.call<{ data: string; width: number | null; height: number | null; path: string }>(method, { ...params, inline: true }, 30_000);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, Buffer.from(shot.data, "base64"));
    return { kind: "screenshot", path, metadata: { scope, width: shot.width, height: shot.height, remote: this.client.url, remotePath: shot.path } };
  }

  /** Fetch a file the host wrote, in chunks, to a local path. */
  private async download(remotePath: string, localPath: string): Promise<void> {
    const chunks: Buffer[] = [];
    let offset = 0;
    for (;;) {
      const part = await this.client.call<{ data: string; length: number; eof: boolean }>("files.read", { path: remotePath, offset }, 120_000);
      chunks.push(Buffer.from(part.data, "base64"));
      offset += part.length;
      if (part.eof || part.length === 0) break;
    }
    await mkdir(dirname(localPath), { recursive: true });
    await writeFile(localPath, Buffer.concat(chunks));
  }
}

/**
 * The remote engine when ACTION_REMOTE_HOST (or LATTICES_REMOTE_HOST) names a
 * host, else undefined. `host:port` is accepted.
 */
export function remoteEngineFromEnv(env: Record<string, string | undefined> = process.env): RemoteEngine | undefined {
  const raw = env.ACTION_REMOTE_HOST?.trim() || env.LATTICES_REMOTE_HOST?.trim();
  if (!raw) return undefined;
  const [host, port] = raw.split(":");
  return new RemoteEngine({ host, port: port ? Number(port) : undefined, recordFps: env.ACTION_REMOTE_FPS ? Number(env.ACTION_REMOTE_FPS) : undefined });
}
