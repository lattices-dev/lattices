import { randomUUID } from "node:crypto";
import { mkdir, open, rename, unlink } from "node:fs/promises";
import { join } from "node:path";
import { checkDeadline, outsideRequestDeadline, withDeadline } from "./transport.ts";

type Json = Record<string, unknown>;
export type RecordingConnection = { call(method: string, params?: Json): Promise<Json>; close(): void };
export type FrameScheduling = "default" | "uncapped" | "no-vsync" | "capture-60";

export function parseFrameScheduling(value: unknown): FrameScheduling | undefined {
  if (value === undefined || value === "default" || value === "uncapped" || value === "no-vsync" || value === "capture-60") return value;
  throw new Error("frameScheduling must be default, uncapped, no-vsync, or capture-60.");
}

export function frameSchedulingFlags(mode?: FrameScheduling): string[] {
  // Chromium's switch also disables GPU vsync. It removes a cap, not a promise
  // that the page or its recording will produce any particular frame rate.
  return mode === "uncapped" ? ["--disable-frame-rate-limit"] : mode === "no-vsync" ? ["--disable-gpu-vsync"] : mode === "capture-60" ? ["--enable-features=ForceMacVSyncTimerForDebugging", "--disable-features=UseDisplayRefreshRateForTimer"] : [];
}

/** Match an owned process's effective switches, including merged feature lists. */
export function frameSchedulingFromCommand(command: string): FrameScheduling | undefined {
  const switches = new Map<string, string>();
  for (const match of command.matchAll(/(?:^|\s)--([a-z0-9-]+)(?:=([^\s]*))?/g)) switches.set(match[1], match[2] ?? "");
  const features = (name: string) => new Set((switches.get(name) ?? "").split(",").map(value => value.split(/[<:]/)[0]));
  const enabled = features("enable-features"), disabled = features("disable-features");
  const timer = enabled.has("ForceMacVSyncTimerForDebugging"), fixed = disabled.has("UseDisplayRefreshRateForTimer");
  const uncapped = switches.has("disable-frame-rate-limit"), noVsync = switches.has("disable-gpu-vsync");
  if (timer || fixed) {
    if (!timer || !fixed || uncapped || noVsync || disabled.has("ForceMacVSyncTimerForDebugging") || enabled.has("UseDisplayRefreshRateForTimer")) return undefined;
    return "capture-60";
  }
  return uncapped ? "uncapped" : noVsync ? "no-vsync" : "default";
}

export function supportsScreenRecording(protocol: unknown): boolean {
  const domains = (protocol as { domains?: Array<{ domain?: string; commands?: Array<{ name?: string }> }> })?.domains;
  const page = Array.isArray(domains) ? domains.find(domain => domain.domain === "Page") : undefined;
  return ["startScreenRecording", "stopScreenRecording"].every(name => page?.commands?.some(command => command.name === name));
}

export function parseRecordingOptions(args: Json) {
  const integer = (name: string, fallback: number, min: number, max: number) => {
    const value = args[name] ?? fallback;
    if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
      throw new Error(`${name} must be an integer from ${min} to ${max}.`);
    }
    return value;
  };
  return {
    frameRate: integer("frameRate", 60, 1, 120),
    maxWidth: integer("maxWidth", 1920, 16, 3840),
    maxHeight: integer("maxHeight", 1080, 16, 2160),
    maxDurationMs: integer("maxDurationMs", 60_000, 1000, 120_000),
  };
}

type Active = {
  id: string; tabId: string; session: RecordingConnection; stream: string;
  startedAt: string; options: ReturnType<typeof parseRecordingOptions>;
  timer?: ReturnType<typeof setTimeout>; starting?: Promise<void>; stopping?: Promise<Json>;
};

/** One recording per MCP owner. The encoded stream is copied, never resampled. */
export class BrowserRecordings {
  private active?: Active;
  private last?: { id: string; result?: Json; error?: Error };
  constructor(private artifactRoot: string, private maximumBytes = 256 * 1024 * 1024, private flushTimeoutMs = 30_000) {}

  get tabId(): string | undefined { return this.active?.tabId; }

  async start(session: RecordingConnection, tabId: string, args: Json): Promise<Json> {
    if (this.active) { session.close(); throw new Error("Stop the current browser recording before starting another."); }
    const options = parseRecordingOptions(args);
    const active: Active = { id: randomUUID(), tabId, session, stream: "", startedAt: new Date().toISOString(), options };
    this.active = active; // Reserve before awaiting; concurrent starts cannot share an owner.
    try {
      active.starting = (async () => {
        const result = await session.call("Page.startScreenRecording", {
          audio: false, frameRate: options.frameRate, maxWidth: options.maxWidth, maxHeight: options.maxHeight,
        });
        if (this.active !== active) throw new Error("Recording owner closed during startup.");
        if (typeof result.stream !== "string" || !result.stream) throw new Error("Chrome did not return a recording stream.");
        active.stream = result.stream;
        active.timer = outsideRequestDeadline(() => setTimeout(() => { void this.stop(active.id, "duration-limit").catch(() => {}); }, options.maxDurationMs));
        active.timer.unref();
      })();
      await active.starting;
      return { recordingId: active.id, tabId, status: "recording", startedAt: active.startedAt,
        requestedFrameRate: options.frameRate, maxDurationMs: options.maxDurationMs,
        source: "Page.startScreenRecording", frameRateGuaranteed: false };
    } catch (error) {
      if (this.active === active) this.active = undefined;
      session.close(); throw error;
    }
  }

  async stop(id: string, reason = "requested"): Promise<Json> {
    const active = this.active;
    if (!active || active.id !== id) {
      if (this.last?.id === id) {
        if (this.last.error) throw this.last.error;
        return this.last.result!;
      }
      throw new Error("Unknown recordingId for this MCP session.");
    }
    await active.starting;
    if (this.active !== active) throw new Error("Recording owner closed during startup.");
    if (active.stopping) return active.stopping;
    clearTimeout(active.timer);
    active.stopping = this.finish(active, reason);
    return active.stopping;
  }

  private async finish(active: Active, reason: string): Promise<Json> {
    const outputPath = join(this.artifactRoot, `browser-${active.id}.mp4`);
    const partialPath = `${outputPath}.partial`;
    try {
      const result = await withDeadline(this.flushTimeoutMs, "Flush browser recording", async () => {
        // The worker owns file cleanup even if the outer deadline rejects while
        // a filesystem await is still settling. Never publish after expiry.
        let file: Awaited<ReturnType<typeof open>> | undefined;
        let published = false;
        let complete = false;
        try {
          const stopped = await active.session.call("Page.stopScreenRecording");
          if (typeof stopped.stream !== "string" || !stopped.stream) throw new Error("Chrome did not finish its recording stream.");
          active.stream = stopped.stream;
          await mkdir(this.artifactRoot, { recursive: true, mode: 0o700 });
          checkDeadline();
          file = await open(partialPath, "wx", 0o600);
          checkDeadline();
          let bytes = 0;
          for (;;) {
            const chunk = await active.session.call("IO.read", { handle: active.stream, size: 1024 * 1024 });
            if (typeof chunk.data !== "string") throw new Error("Chrome returned invalid recording data.");
            const data = Buffer.from(chunk.data, chunk.base64Encoded === true ? "base64" : "utf8");
            bytes += data.length;
            if (bytes > this.maximumBytes) throw new Error("Browser recording exceeded its byte limit.");
            await file.writeFile(data);
            checkDeadline();
            if (chunk.eof === true) break;
            if (!data.length) throw new Error("Chrome returned an unfinished empty recording stream.");
          }
          if (!bytes) throw new Error("Chrome returned an empty recording.");
          await file.sync(); checkDeadline();
          await file.close(); file = undefined; checkDeadline();
          await rename(partialPath, outputPath); published = true; checkDeadline();
          complete = true;
          return { recordingId: active.id, tabId: active.tabId, status: "finished", reason,
            outputPath, bytes, startedAt: active.startedAt, finishedAt: new Date().toISOString(),
            requestedFrameRate: active.options.frameRate, source: "Page.startScreenRecording",
            frameRateGuaranteed: false, timestampsPreserved: true };
        } finally {
          await file?.close().catch(() => {});
          await unlink(partialPath).catch(() => {});
          if (published && !complete) await unlink(outputPath).catch(() => {});
          if (active.stream) await active.session.call("IO.close", { handle: active.stream }).catch(() => {});
        }
      });
      this.last = { id: active.id, result }; return result;
    } catch (error) {
      this.last = { id: active.id, error: error instanceof Error ? error : new Error(String(error)) };
      throw error;
    } finally {
      active.session.close();
      if (this.active === active) this.active = undefined;
    }
  }

  async shutdown(): Promise<void> {
    if (this.active) await this.stop(this.active.id, "owner-close").catch(() => {});
  }

  closeSync(): void {
    if (!this.active) return;
    clearTimeout(this.active.timer); this.active.session.close(); this.active = undefined;
  }
}
