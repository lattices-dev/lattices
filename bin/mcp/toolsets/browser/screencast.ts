import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { outsideRequestDeadline } from "./transport.ts";
import { parseRecordingOptions } from "./recording.ts";

type Json = Record<string, unknown>;
export type ScreencastConnection = {
  call(method: string, params?: Json): Promise<Json>;
  on(method: string, listener: (params: Json) => void): () => void;
  close(): void;
};
export type SourceFrame = { index: number; timestampSeconds: number; receivedAt: number; file: string; bytes: number; metadata?: Record<string, number> };
export type ScreencastEncoder = (directory: string, frames: SourceFrame[], outputPath: string, signal: AbortSignal) => Promise<Json>;

function run(command: string, args: string[], timeoutMs: number, signal: AbortSignal): Promise<string> {
  return new Promise((resolve, reject) => {
    signal.throwIfAborted();
    const child = spawn(command, args, {stdio: ["ignore", "pipe", "pipe"]});
    let output = "", error = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    const abort = () => { child.kill("SIGKILL"); };
    signal.addEventListener("abort", abort, {once: true});
    child.stdout.on("data", data => { if (output.length < 4_000_000) output += String(data); });
    child.stderr.on("data", data => { if (error.length < 16000) error += String(data); });
    child.once("error", failure => { clearTimeout(timer); signal.removeEventListener("abort", abort); reject(failure); });
    child.once("close", (code, exitSignal) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", abort);
      if (code !== 0) reject(new Error(`${command} failed (${exitSignal ?? code}): ${error.slice(-4000)}`));
      else resolve(output);
    });
  });
}

export async function prepareScreencastPresentation(directory: string, frames: SourceFrame[], signal: AbortSignal) {
  signal.throwIfAborted();
  // JPEG encodes can arrive out of presentation order. Keep the raw event
  // order in the sidecar, and order presentation by Chrome's source PTS.
  const ordered = [...frames].sort((a, b) => a.timestampSeconds - b.timestampSeconds || a.index - b.index);
  const presentation: SourceFrame[] = [];
  let duplicateSourceEvents = 0;
  for (const frame of ordered) {
    const previous = presentation.at(-1);
    if (previous && previous.timestampSeconds === frame.timestampSeconds) {
      const left = await readFile(join(directory, previous.file)), right = await readFile(join(directory, frame.file));
      signal.throwIfAborted();
      if (!left.equals(right)) throw new Error(`Conflicting JPEG frames share source timestamp ${frame.timestampSeconds}; raw frames and timestamps were preserved.`);
      duplicateSourceEvents++;
    } else presentation.push(frame);
  }
  return {frames: presentation, duplicateSourceEvents, reorderedSourceEvents: ordered.filter((frame, index) => frame.index !== frames[index].index).length, presentationOrder: presentation.map(frame => frame.index)};
}

/** Encode only after capture. Concat durations retain each captured timestamp. */
export const encodeScreencast: ScreencastEncoder = async (directory, frames, outputPath, signal) => {
  const prepared = await prepareScreencastPresentation(directory, frames, signal);
  frames = prepared.frames;
  const concat = ["ffconcat version 1.0"];
  const ticks = frames.map(frame => Math.round((frame.timestampSeconds - frames[0].timestampSeconds) * 1_000_000));
  frames.forEach((frame, index) => {
    concat.push(`file '${frame.file}'`, "option framerate 1000000");
    if (index + 1 < frames.length) concat.push(`duration ${((ticks[index + 1] - ticks[index]) / 1_000_000).toFixed(6)}`);
  });
  const manifest = join(directory, "frames.ffconcat");
  await writeFile(manifest, concat.join("\n") + "\n", {mode: 0o600, flag: "wx"});
  signal.throwIfAborted();
  const partial = `${outputPath}.partial.mp4`;
  try {
    await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-n", "-f", "concat", "-safe", "0", "-i", manifest,
      "-an", "-fps_mode", "passthrough", "-enc_time_base", "1/1000000", "-c:v", "h264_videotoolbox", "-allow_sw", "0",
      "-b:v", "12000k", "-bf", "0", "-pix_fmt", "yuv420p", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-video_track_timescale", "1000000", partial], 120_000, signal);
    const probe = JSON.parse(await run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_packets", "-show_entries", "packet=pts_time", "-of", "json", partial], 30_000, signal)) as {packets?: Array<{pts_time?: string}>};
    const timestamps = (probe.packets ?? []).map(packet => Number(packet.pts_time)).sort((a, b) => a - b);
    if (timestamps.length !== frames.length) throw new Error(`Encoded frame count ${timestamps.length} differs from captured count ${frames.length}.`);
    const origin = frames[0].timestampSeconds;
    let maximumTimestampErrorSeconds = 0;
    frames.forEach((frame, index) => {
      maximumTimestampErrorSeconds = Math.max(maximumTimestampErrorSeconds, Math.abs((frame.timestampSeconds - origin) - timestamps[index]));
    });
    if (maximumTimestampErrorSeconds > 0.000003) throw new Error(`Encoding changed source timestamps by ${maximumTimestampErrorSeconds}s.`);
    signal.throwIfAborted(); await rename(partial, outputPath);
    const presentationPath = join(directory, "presentation.json");
    await writeFile(presentationPath, JSON.stringify({schemaVersion: 1, order: prepared.presentationOrder, duplicateSourceEvents: prepared.duplicateSourceEvents, reorderedSourceEvents: prepared.reorderedSourceEvents, maximumTimestampErrorSeconds}), {mode: 0o600, flag: "wx"});
    return {encodedFrames: timestamps.length, duplicateSourceEvents: prepared.duplicateSourceEvents, reorderedSourceEvents: prepared.reorderedSourceEvents, presentationPath, maximumTimestampErrorSeconds, encoder: "h264_videotoolbox", hardwareRequired: true, frameInterpolation: false};
  } finally { await unlink(partial).catch(() => {}); }
};

type Active = {
  id: string; tabId: string; session: ScreencastConnection; startedAt: string;
  frames: Array<{data: Buffer; timestampSeconds: number; receivedAt: number; metadata: Record<string, number>}>; bytes: number;
  timer?: ReturnType<typeof setTimeout>; unsubscribe?: () => void; failure?: Error;
  starting?: Promise<void>; stopping?: Promise<Json>;
  abort: AbortController;
};

export class BrowserScreencasts {
  private active?: Active;
  private last?: {id: string; result?: Json; error?: Error};
  constructor(private artifactRoot: string, private options: {maximumBytes?: number; maximumFrames?: number; encode?: ScreencastEncoder; finishTimeoutMs?: number} = {}) {}
  get tabId(): string | undefined { return this.active?.tabId; }

  async start(session: ScreencastConnection, tabId: string, args: Json): Promise<Json> {
    if (this.active) { session.close(); throw new Error("Stop the current browser recording before starting another."); }
    let options: ReturnType<typeof parseRecordingOptions>;
    try { options = parseRecordingOptions(args); } catch (error) { session.close(); throw error; }
    const active: Active = {id: randomUUID(), tabId, session, startedAt: new Date().toISOString(), frames: [], bytes: 0, abort: new AbortController()};
    this.active = active;
    const fail = (error: unknown) => {
      active.failure ??= error instanceof Error ? error : new Error(String(error));
      outsideRequestDeadline(() => { void this.stop(active.id, "capture-failed").catch(() => {}); });
    };
    active.unsubscribe = session.on("Page.screencastFrame", event => {
      if (this.active !== active || active.failure) return;
      const sourceMetadata = event.metadata as Json | undefined;
      const timestamp = sourceMetadata?.timestamp;
      if (typeof event.data !== "string" || typeof timestamp !== "number" || !Number.isFinite(timestamp) || typeof event.sessionId !== "number") return fail("Chrome returned an invalid screencast frame.");
      if (event.data.length > 16 * 1024 * 1024) return fail("Screencast frame exceeded its individual byte limit.");
      const data = Buffer.from(event.data, "base64");
      if (data.length < 4 || data[0] !== 0xff || data[1] !== 0xd8) return fail("Chrome returned an invalid JPEG frame.");
      if (active.frames.length >= (this.options.maximumFrames ?? 18000) || active.bytes + data.length > (this.options.maximumBytes ?? 256 * 1024 * 1024)) return fail("Screencast capture exceeded its bounded frame storage; no frames were silently discarded.");
      const metadata: Record<string, number> = {};
      for (const key of ["offsetTop", "pageScaleFactor", "deviceWidth", "deviceHeight", "scrollOffsetX", "scrollOffsetY"]) {
        const value = sourceMetadata?.[key];
        if (typeof value === "number" && Number.isFinite(value)) metadata[key] = value;
      }
      active.frames.push({data, timestampSeconds: timestamp, receivedAt: Date.now(), metadata}); active.bytes += data.length;
      // ACK only after bounded storage accepts the complete frame. No encoding
      // or filesystem work can hold Chrome's capture buffer during recording.
      outsideRequestDeadline(() => { void session.call("Page.screencastFrameAck", {sessionId: event.sessionId}).catch(fail); });
    });
    try {
      active.starting = (async () => {
        await session.call("Page.startScreencast", {format: "jpeg", quality: 90, maxWidth: options.maxWidth, maxHeight: options.maxHeight, everyNthFrame: 1});
        if (this.active !== active) throw new Error("Recording owner closed during startup.");
        active.timer = outsideRequestDeadline(() => setTimeout(() => { void this.stop(active.id, "duration-limit").catch(() => {}); }, options.maxDurationMs)); active.timer.unref();
      })();
      await active.starting;
      return {recordingId: active.id, tabId, status: "recording", startedAt: active.startedAt, source: "Page.startScreencast", everyNthFrame: 1, quality: 90, maxDurationMs: options.maxDurationMs, frameRateGuaranteed: false, encoding: "after-stop", maximumBytes: this.options.maximumBytes ?? 256 * 1024 * 1024};
    } catch (error) { active.unsubscribe?.(); session.close(); if (this.active === active) this.active = undefined; throw error; }
  }

  async stop(id: string, reason = "requested"): Promise<Json> {
    const active = this.active;
    if (!active || active.id !== id) {
      if (this.last?.id === id) { if (this.last.error) throw this.last.error; return this.last.result!; }
      throw new Error("Unknown recordingId for this MCP session.");
    }
    await active.starting;
    if (this.active !== active) throw new Error("Recording owner closed during startup.");
    if (active.stopping) return active.stopping;
    clearTimeout(active.timer);
    active.stopping = this.finish(active, reason); return active.stopping;
  }

  private async finish(active: Active, reason: string): Promise<Json> {
    const timer = outsideRequestDeadline(() => setTimeout(() => active.abort.abort(new Error("Screencast finalization timed out.")), this.options.finishTimeoutMs ?? 120_000)); timer.unref();
    let rejectAbort: (() => void) | undefined;
    const aborted = new Promise<never>((_, reject) => {
      rejectAbort = () => reject(active.abort.signal.reason ?? new Error("Recording owner closed."));
      active.abort.signal.addEventListener("abort", rejectAbort, {once: true});
      if (active.abort.signal.aborted) rejectAbort();
    });
    try {
      const work = async () => {
      active.abort.signal.throwIfAborted();
      await active.session.call("Page.stopScreencast"); active.unsubscribe?.();
      active.abort.signal.throwIfAborted();
      const capturedAt = new Date().toISOString();
      const directory = join(this.artifactRoot, `screencast-${active.id}`);
      await mkdir(directory, {recursive: true, mode: 0o700});
      active.abort.signal.throwIfAborted();
      const frames: SourceFrame[] = [];
      for (let index = 0; index < active.frames.length; index++) {
        const frame = active.frames[index], file = `${String(index).padStart(6, "0")}.jpg`;
        await writeFile(join(directory, file), frame.data, {mode: 0o600, flag: "wx"});
        active.abort.signal.throwIfAborted();
        frames.push({index, file, bytes: frame.data.length, timestampSeconds: frame.timestampSeconds, receivedAt: frame.receivedAt, metadata: frame.metadata});
      }
      const chronological = [...frames].sort((a, b) => a.timestampSeconds - b.timestampSeconds);
      const intervals = chronological.slice(1).map((frame, index) => (frame.timestampSeconds - chronological[index].timestampSeconds) * 1000);
      const sorted = [...intervals].sort((a, b) => a - b);
      const cadence = {frames: frames.length, spanSeconds: frames.length ? chronological.at(-1)!.timestampSeconds - chronological[0].timestampSeconds : 0, medianIntervalMs: sorted[Math.floor(sorted.length / 2)], p95IntervalMs: sorted[Math.floor(sorted.length * .95)], maximumIntervalMs: sorted.at(-1), gapsOver25ms: intervals.filter(value => value > 25).length, gapsOver100ms: intervals.filter(value => value > 100).length};
      const timestampPath = join(directory, "timestamps.json");
      await writeFile(timestampPath, JSON.stringify({schemaVersion: 1, source: "Page.screencastFrame", timestampUnit: "seconds since epoch (CDP TimeSinceEpoch)", order: "arrival", startedAt: active.startedAt, capturedAt, frames, cadence, captureFailure: active.failure?.message}), {mode: 0o600, flag: "wx"});
      active.abort.signal.throwIfAborted();
      active.frames.length = 0; // Encoding starts only after capture and source persistence.
      if (active.failure) throw new Error(`${active.failure.message} Accepted source frames preserved at ${directory}`);
      if (frames.length < 2) throw new Error(`Screencast did not deliver enough frames. Source evidence preserved at ${directory}`);
      const outputPath = join(directory, "recording.mp4");
      let encoded: Json;
      try {
        encoded = await (this.options.encode ?? encodeScreencast)(directory, frames, outputPath, active.abort.signal);
        active.abort.signal.throwIfAborted();
      } catch (error) { await unlink(outputPath).catch(() => {}); throw error; }
      const result = {recordingId: active.id, tabId: active.tabId, status: "finished", reason, source: "Page.startScreencast", outputPath, timestampPath, sourceFramesDirectory: directory, startedAt: active.startedAt, capturedAt, finishedAt: new Date().toISOString(), sourceBytes: active.bytes, frameRateGuaranteed: false, timestampsPreserved: true, cadence, ...encoded};
      return result;
      };
      const result = await Promise.race([work(), aborted]); this.last = {id: active.id, result}; return result;
    } catch (error) { this.last = {id: active.id, error: error instanceof Error ? error : new Error(String(error))}; throw error; }
    finally { clearTimeout(timer); if (rejectAbort) active.abort.signal.removeEventListener("abort", rejectAbort); active.unsubscribe?.(); active.session.close(); active.frames.length = 0; if (this.active === active) this.active = undefined; }
  }

  async shutdown(): Promise<void> { if (this.active) await this.stop(this.active.id, "owner-close").catch(() => {}); }
  closeSync(): void { if (!this.active) return; clearTimeout(this.active.timer); this.active.abort.abort(new Error("Recording owner closed.")); this.active.unsubscribe?.(); this.active.session.close(); this.active.frames.length = 0; this.active = undefined; }
}
