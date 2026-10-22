// capture.stream: H.264 of a display, window or region, pushed as binary LVF1
// messages on the requesting connection (layout in
// apps/mac/Sources/Core/Hosts/RemoteVideoFrame.swift). wf-recorder captures
// through wlr-screencopy and writes a raw Annex B stream to stdout; this file
// cuts it into access units and packs each into the wire header.
//
// Flow control: an external encoder can't skip capture, so at 4 unacked
// frames (or a backed-up socket) frames are dropped until the next IDR. The
// encoder's keyint brings one within ~2 s; a stream still waiting after a
// second restarts the encoder, whose first frame is an IDR. Restarting is
// also the only way to honour capture.stream.keyframe.
//
// wf-recorder runs with -D: on Hyprland, damage-driven capture returns no
// picture at all until the screen changes, so a still screen would never show
// and a keyframe restart would stay blank. ffmpeg writes each packet whole, so
// stdout going quiet ends the unit.

import { existsSync } from "node:fs";
import * as desktop from "./desktop.ts";
import { captureTarget } from "./endpoints.ts";
import * as hypr from "./hyprland.ts";
import type { Rect } from "./placement.ts";
import { RouterError, num, str, type Json, type Params } from "./router.ts";

export const STREAM_METHODS = ["capture.stream.start", "capture.stream.ack", "capture.stream.keyframe", "capture.stream.stop"];
export const ENDED_EVENT = "capture.stream.ended";

const HEADER_SIZE = 48;
const MAGIC = [0x4c, 0x56, 0x46, 0x31]; // "LVF1"
const CODEC_H264 = 1;
export const ACK_WINDOW = 4;
export const ACK_TIMEOUT_MS = 3000;
const KEYFRAME_WAIT_MS = 1000;
const QUIET_MS = 8;
const RESTART_SPACING_MS = 2000;
const WINDOW_CHECK_MS = 2000;
const MAX_BUFFERED_BYTES = 4 * 1024 * 1024;
const MAX_STREAMS_PER_CONNECTION = 4;
const VAAPI_DEVICE = "/dev/dri/renderD128";

// ── Annex B ───────────────────────────────────────────────────────────

/** Incremental Annex B scanner: a NAL is complete once the next start code arrives. */
export class NalScanner {
  private buf = new Uint8Array(0);
  private start = -1;
  private scan = 0;

  push(chunk: Uint8Array): Uint8Array[] {
    const joined = new Uint8Array(this.buf.length + chunk.length);
    joined.set(this.buf);
    joined.set(chunk, this.buf.length);
    const buf = joined;
    const out: Uint8Array[] = [];
    let i = this.scan;
    while (i + 2 < buf.length) {
      if (buf[i + 2] > 1) i += 3;
      else if (buf[i] === 0 && buf[i + 1] === 0 && buf[i + 2] === 1) {
        if (this.start >= 0) pushNal(out, buf.subarray(this.start, i));
        this.start = i + 3;
        i += 3;
      } else i += 1;
    }
    // Keep only the unfinished NAL (or, before the first start code, a possible partial one).
    const keepFrom = this.start >= 0 ? this.start : Math.max(0, buf.length - 2);
    this.buf = buf.slice(keepFrom);
    this.scan = Math.max(0, i - keepFrom);
    if (this.start >= 0) this.start = 0;
    return out;
  }

  /** The first bytes of the NAL still arriving, once two are in. */
  peek(): Uint8Array | null {
    return this.start >= 0 && this.buf.length - this.start >= 2 ? this.buf.subarray(this.start, this.start + 2) : null;
  }

  /** The trailing NAL, once the stream has ended. */
  flush(): Uint8Array[] {
    const out: Uint8Array[] = [];
    if (this.start >= 0) pushNal(out, this.buf.subarray(this.start));
    this.buf = new Uint8Array(0);
    this.start = -1;
    this.scan = 0;
    return out;
  }
}

function pushNal(out: Uint8Array[], nal: Uint8Array) {
  // Trailing zeros are the next 4-byte start code's lead or trailing_zero_8bits.
  let end = nal.length;
  while (end > 0 && nal[end - 1] === 0) end--;
  if (end > 0) out.push(nal.subarray(0, end));
}

export const nalType = (nal: Uint8Array) => nal[0] & 0x1f;
const isVcl = (type: number) => type >= 1 && type <= 5;
/** first_mb_in_slice == 0: ue(v) of 0 is a single 1 bit. */
const firstSlice = (nal: Uint8Array) => nal.length > 1 && (nal[1] & 0x80) !== 0;

export interface AccessUnit {
  keyframe: boolean;
  /** Every NAL of the picture, in order, AUD excluded. */
  nals: Uint8Array[];
}

/**
 * Groups NALs into access units (H.264 7.4.1.2.3, enough of it): a new one
 * starts at an AUD, at SPS/PPS/SEI after a picture's slices, or at a slice
 * with first_mb_in_slice 0 once the current unit has a slice. Prefix NALs
 * (parameter sets, SEI) ride with the picture after them. A unit is cut as
 * soon as the head of the next one shows, not when that NAL completes.
 */
export class AccessUnitSplitter {
  private scanner = new NalScanner();
  private current: Uint8Array[] = [];
  private hasVcl = false;

  push(chunk: Uint8Array): AccessUnit[] {
    const out = this.take(this.scanner.push(chunk));
    const head = this.scanner.peek();
    if (head && this.hasVcl && this.starts(head)) out.push(this.cut());
    return out;
  }

  /** Whether this NAL begins a new unit, given the current one has a slice. */
  private starts(nal: Uint8Array) {
    const type = nalType(nal);
    return isVcl(type) ? firstSlice(nal) : type !== 10 && type !== 11 && type !== 12;
  }

  flush(): AccessUnit[] {
    const out = this.take(this.scanner.flush());
    if (this.hasVcl) out.push(this.cut());
    return out;
  }

  /** Input went quiet: a trailing slice is taken as complete. Stays usable. */
  flushPending(): AccessUnit[] {
    const head = this.scanner.peek();
    if (!head || !isVcl(nalType(head))) return [];
    return this.flush();
  }

  private take(nals: Uint8Array[]): AccessUnit[] {
    const out: AccessUnit[] = [];
    for (const nal of nals) {
      const type = nalType(nal);
      if (this.hasVcl && this.starts(nal)) out.push(this.cut());
      if (type === 9 || type === 10 || type === 11 || type === 12) continue;
      if (isVcl(type)) this.hasVcl = true;
      this.current.push(nal);
    }
    return out;
  }

  private cut(): AccessUnit {
    const nals = this.current;
    this.current = [];
    this.hasVcl = false;
    return { keyframe: nals.some((n) => nalType(n) === 5), nals };
  }
}

// ── SPS ───────────────────────────────────────────────────────────────

class BitReader {
  private bit = 0;
  constructor(private bytes: Uint8Array) {}
  u(n: number): number {
    let v = 0;
    for (let i = 0; i < n; i++) {
      const byte = this.bytes[this.bit >> 3];
      if (byte === undefined) throw new Error("SPS truncated");
      v = v * 2 + ((byte >> (7 - (this.bit & 7))) & 1);
      this.bit++;
    }
    return v;
  }
  ue(): number {
    let zeros = 0;
    while (this.u(1) === 0) if (++zeros > 31) throw new Error("bad exp-Golomb");
    return 2 ** zeros - 1 + this.u(zeros);
  }
  se(): number {
    const k = this.ue();
    return k & 1 ? (k + 1) / 2 : -(k / 2);
  }
}

function unescapeRbsp(nal: Uint8Array): Uint8Array {
  const out: number[] = [];
  let zeros = 0;
  for (const byte of nal) {
    if (zeros >= 2 && byte === 3) {
      zeros = 0;
      continue;
    }
    out.push(byte);
    zeros = byte === 0 ? zeros + 1 : 0;
  }
  return Uint8Array.from(out);
}

/** Display size an H.264 SPS describes (cropping applied); null if unreadable. */
export function spsSize(sps: Uint8Array): { width: number; height: number } | null {
  try {
    const r = new BitReader(unescapeRbsp(sps.subarray(1)));
    const profile = r.u(8);
    r.u(16); // constraint flags, level
    r.ue(); // sps id
    let chroma = 1;
    let separate = 0;
    if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].includes(profile)) {
      chroma = r.ue();
      if (chroma === 3) separate = r.u(1);
      r.ue(); r.ue(); r.u(1); // bit depths, qpprime bypass
      if (r.u(1)) {
        for (let i = 0; i < (chroma !== 3 ? 8 : 12); i++) {
          if (!r.u(1)) continue;
          let last = 8, next = 8;
          for (let j = 0; j < (i < 6 ? 16 : 64); j++) {
            if (next !== 0) next = (last + r.se() + 256) % 256;
            last = next === 0 ? last : next;
          }
        }
      }
    }
    r.ue(); // log2_max_frame_num
    const poc = r.ue();
    if (poc === 0) r.ue();
    else if (poc === 1) {
      r.u(1); r.se(); r.se();
      const n = r.ue();
      for (let i = 0; i < n; i++) r.se();
    }
    r.ue(); r.u(1); // max refs, gaps
    const mbsW = r.ue() + 1;
    const mapH = r.ue() + 1;
    const frameMbsOnly = r.u(1);
    if (!frameMbsOnly) r.u(1);
    r.u(1); // direct_8x8
    let [left, right, top, bottom] = [0, 0, 0, 0];
    if (r.u(1)) [left, right, top, bottom] = [r.ue(), r.ue(), r.ue(), r.ue()];
    const arrayType = separate ? 0 : chroma;
    const cropX = arrayType === 0 ? 1 : arrayType === 3 ? 1 : 2;
    const cropY = (arrayType === 1 ? 2 : 1) * (2 - frameMbsOnly);
    return {
      width: mbsW * 16 - cropX * (left + right),
      height: (2 - frameMbsOnly) * mapH * 16 - cropY * (top + bottom),
    };
  } catch {
    return null;
  }
}

// ── Wire frame ────────────────────────────────────────────────────────

export interface FrameFields {
  streamId: number;
  seq: number;
  keyframe: boolean;
  pts: bigint;
  width: number;
  height: number;
  frame: Rect;
  /** SPS then PPS, on keyframes. */
  parameterSets: Uint8Array[];
  /** NAL units without start codes; written with u32 length prefixes. */
  nals: Uint8Array[];
}

export function packFrame(f: FrameFields): Uint8Array {
  const setsSize = f.parameterSets.length ? 2 + f.parameterSets.reduce((n, s) => n + 2 + s.length, 0) : 0;
  const auSize = f.nals.reduce((n, s) => n + 4 + s.length, 0);
  const out = new Uint8Array(HEADER_SIZE + setsSize + auSize);
  const view = new DataView(out.buffer);
  out.set(MAGIC, 0);
  view.setUint32(4, f.streamId);
  view.setUint32(8, f.seq);
  out[12] = (f.keyframe ? 1 : 0) | (f.parameterSets.length ? 2 : 0);
  out[13] = CODEC_H264;
  view.setUint16(14, 0);
  view.setBigUint64(16, f.pts);
  view.setUint32(24, f.width);
  view.setUint32(28, f.height);
  view.setFloat32(32, f.frame.x);
  view.setFloat32(36, f.frame.y);
  view.setFloat32(40, f.frame.w);
  view.setFloat32(44, f.frame.h);
  let at = HEADER_SIZE;
  if (f.parameterSets.length) {
    view.setUint16(at, f.parameterSets.length);
    at += 2;
    for (const set of f.parameterSets) {
      view.setUint16(at, set.length);
      out.set(set, at + 2);
      at += 2 + set.length;
    }
  }
  for (const nal of f.nals) {
    view.setUint32(at, nal.length);
    out.set(nal, at + 4);
    at += 4 + nal.length;
  }
  return out;
}

/** Splits an access unit into its parameter sets and the picture's NALs. */
export function splitParameterSets(au: AccessUnit) {
  const sps: Uint8Array[] = [], pps: Uint8Array[] = [], picture: Uint8Array[] = [];
  for (const nal of au.nals) {
    const type = nalType(nal);
    if (type === 7) sps.push(nal);
    else if (type === 8) pps.push(nal);
    else picture.push(nal);
  }
  return { sps, pps, picture };
}

// ── Flow control ──────────────────────────────────────────────────────

/** Cumulative acks; at the window the chain is broken and only an IDR resumes it. */
export class FlowControl {
  lastSent = 0;
  lastAcked = 0;
  /** True until the first keyframe, and after any drop until the next one. */
  dropping = true;
  private waitingSince: number | null = null;

  constructor(readonly window = ACK_WINDOW, readonly timeoutMs = ACK_TIMEOUT_MS) {}

  get inFlight() { return this.lastSent - this.lastAcked; }

  /** Whether to send this picture; `congested` is a backed-up socket. */
  admit(keyframe: boolean, congested = false): boolean {
    if (this.dropping && !keyframe) return false;
    if (this.inFlight >= this.window || congested) {
      this.dropping = true;
      return false;
    }
    this.dropping = false;
    return true;
  }

  /** Records a send; returns its seq. */
  sent(now: number): number {
    this.lastSent += 1;
    this.waitingSince ??= now;
    return this.lastSent;
  }

  ack(seq: number, now: number) {
    if (!(seq > this.lastAcked && seq <= this.lastSent)) return;
    this.lastAcked = seq;
    this.waitingSince = this.inFlight > 0 ? now : null;
  }

  /** Frames outstanding and no ack for the timeout. */
  timedOut(now: number) {
    return this.waitingSince !== null && now - this.waitingSince >= this.timeoutMs;
  }
}

// ── Encoder ───────────────────────────────────────────────────────────

export type EncoderKind = "vaapi" | "software";

export interface EncoderOptions {
  output?: string;
  region?: Rect;
  width: number;
  height: number;
  fps: number;
  encoder: EncoderKind;
  device?: string;
}

const even = (v: number) => Math.max(2, Math.floor(v / 2) * 2);
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Encoded size: the target's pixels, no wider than maxWidth, both even for 4:2:0. */
export function streamSize(pixelWidth: number, frame: Rect, maxWidth: number) {
  const natural = Math.max(2, pixelWidth);
  const width = even(Math.min(maxWidth, natural));
  const height = even((natural * (frame.h / Math.max(1, frame.w))) * (width / natural));
  return { width, height };
}

/** About 0.1 bit per pixel per frame, 0.5–20 Mbps. */
export function bitrateFor(width: number, height: number, fps: number) {
  return clamp(Math.round(width * height * fps * 0.1), 500_000, 20_000_000);
}

/**
 * wf-recorder writing raw H.264 (Annex B) to stdout. Flags from wf-recorder
 * 0.4/0.5's documented options; -p goes to the codec as an AVOption, so the
 * generic g/bf/b/maxrate/bufsize apply to both encoders.
 */
export function encoderCommand(o: EncoderOptions): { command: string; args: string[] } {
  const args: string[] = [];
  if (o.region) {
    const r = o.region;
    // Logical layout coordinates, as slurp prints them. A region must sit on one output.
    args.push("-g", `${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.w)}x${Math.round(r.h)}`);
  } else if (o.output) {
    args.push("-o", o.output);
  }
  // Every frame, not just damaged ones (see the top of this file).
  args.push("-D", "-r", String(o.fps));
  const bitrate = bitrateFor(o.width, o.height, o.fps);
  if (o.encoder === "vaapi") {
    // Unverified: wf-recorder uploads frames before the user filter for VAAPI,
    // so scaling is scale_vaapi on the GPU (its README's -F example is scale_vaapi).
    args.push("-c", "h264_vaapi", "-d", o.device ?? VAAPI_DEVICE, "-F", `scale_vaapi=w=${o.width}:h=${o.height}:format=nv12`);
  } else {
    args.push(
      "-c", "libx264", "-x", "yuv420p", "-F", `scale=${o.width}:${o.height}`,
      "-p", "preset=ultrafast", "-p", "tune=zerolatency",
      "-p", `maxrate=${bitrate}`, "-p", `bufsize=${Math.round(bitrate / 2)}`,
    );
  }
  args.push(
    "-p", "profile=main", "-p", "bf=0", "-p", `g=${Math.max(1, Math.round(o.fps * 2))}`, "-p", `b=${bitrate}`,
    // The raw h264 muxer writes Annex B. pipe:1 rather than /dev/stdout: wf-recorder
    // asks before overwriting an existing file, and a protocol URL isn't one.
    "-m", "h264", "-f", "pipe:1",
  );
  return { command: "wf-recorder", args };
}

export interface EncoderProcess {
  stdout: ReadableStream<Uint8Array>;
  stderr: ReadableStream<Uint8Array>;
  exited: Promise<number>;
  kill(signal?: NodeJS.Signals | number): void;
}

export function spawnEncoder(cmd: { command: string; args: string[] }): EncoderProcess {
  const proc = Bun.spawn([cmd.command, ...cmd.args], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  return { stdout: proc.stdout, stderr: proc.stderr, exited: proc.exited, kill: (signal) => proc.kill(signal) };
}

// ── Sessions ──────────────────────────────────────────────────────────

export interface StreamSink {
  /** ws.send: bytes sent, -1 queued under backpressure, 0 dropped. */
  send(bytes: Uint8Array): number;
  buffered(): number;
  event(name: string, data: Json): void;
}

export interface StreamDeps {
  snapshot: typeof desktop.snapshot;
  resolveTarget: typeof desktop.resolveTarget;
  spawn: (cmd: { command: string; args: string[] }) => EncoderProcess;
  now: () => number;
  /** Microseconds, host clock. */
  pts: () => bigint;
  windowAlive: (wid: number) => Promise<boolean>;
  /** VAAPI render node, or null to encode in software. */
  vaapiDevice: () => string | null;
  tickMs: number;
  /** Stdout silence that ends the trailing access unit. */
  quietMs: number;
}

export const defaultStreamDeps: StreamDeps = {
  snapshot: desktop.snapshot,
  resolveTarget: desktop.resolveTarget,
  spawn: spawnEncoder,
  now: () => Date.now(),
  pts: () => BigInt(Math.round((performance.timeOrigin + performance.now()) * 1000)),
  windowAlive: async (wid) => (await hypr.clients()).some((c) => c.mapped && desktop.widFor(c) === wid),
  // Opt-in: on Archie (AMD, wf-recorder 0.6) h264_vaapi writes nothing and never exits.
  vaapiDevice: () => process.env.LATTICES_STREAM_ENCODER === "vaapi" && existsSync(VAAPI_DEVICE) ? VAAPI_DEVICE : null,
  tickMs: 250,
  quietMs: QUIET_MS,
};

let nextStreamId = 1;

export class StreamSession {
  readonly flow = new FlowControl();
  encoder: EncoderKind;
  private proc: EncoderProcess | null = null;
  private generation = 0;
  private framesThisProcess = 0;
  private sps: Uint8Array[] = [];
  private pps: Uint8Array[] = [];
  private coded: { width: number; height: number } | null = null;
  private wantKeyframeSince: number | null = null;
  private lastRestart = 0;
  private lastWindowCheck = 0;
  private stderrTail = "";
  private timer: ReturnType<typeof setInterval> | null = null;
  stopped = false;

  constructor(
    readonly id: number,
    readonly target: { output?: string; region?: Rect; frame: Rect; wid: number | null },
    readonly width: number,
    readonly height: number,
    readonly fps: number,
    private sink: StreamSink,
    private deps: StreamDeps,
    private onEnd: (session: StreamSession) => void,
  ) {
    this.encoder = deps.vaapiDevice() ? "vaapi" : "software";
  }

  start() {
    this.lastRestart = this.deps.now();
    this.spawn();
    this.timer = setInterval(() => void this.tick(), this.deps.tickMs);
  }

  command() {
    return encoderCommand({
      output: this.target.output, region: this.target.region, width: this.width, height: this.height,
      fps: this.fps, encoder: this.encoder, device: this.deps.vaapiDevice() ?? undefined,
    });
  }

  private spawn() {
    const generation = ++this.generation;
    this.framesThisProcess = 0;
    this.stderrTail = "";
    const encoder = this.encoder;
    const proc = this.deps.spawn(this.command());
    this.proc = proc;
    const splitter = new AccessUnitSplitter();
    const live = () => !this.stopped && generation === this.generation;
    void (async () => {
      const reader = proc.stdout.getReader();
      let quiet: ReturnType<typeof setTimeout> | null = null;
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (quiet) clearTimeout(quiet);
          quiet = null;
          if (done || !live()) break;
          for (const au of splitter.push(value)) this.onAccessUnit(au);
          quiet = setTimeout(() => {
            quiet = null;
            if (live()) for (const au of splitter.flushPending()) this.onAccessUnit(au);
          }, this.deps.quietMs);
        }
      } catch {}
    })();
    void (async () => {
      const decoder = new TextDecoder();
      const reader = proc.stderr.getReader();
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          if (live()) this.stderrTail = (this.stderrTail + decoder.decode(value)).slice(-600);
        }
      } catch {}
    })();
    void proc.exited.then((code) => {
      if (!live()) return;
      if (encoder === "vaapi" && this.framesThisProcess === 0) {
        // No hardware encode here; software from now on.
        this.encoder = "software";
        this.spawn();
        return;
      }
      const detail = this.stderrTail.trim().split("\n").pop();
      this.end(`encoder-failed: exited (${code})${detail ? `: ${detail}` : ""}`);
    });
  }

  onAccessUnit(au: AccessUnit) {
    if (this.stopped) return;
    this.framesThisProcess += 1;
    const { sps, pps, picture } = splitParameterSets(au);
    if (sps.length) {
      this.sps = sps;
      this.coded = spsSize(sps[0]);
    }
    if (pps.length) this.pps = pps;
    const now = this.deps.now();
    const parameterSets = au.keyframe ? [...this.sps, ...this.pps] : [];
    if (au.keyframe && (!this.sps.length || !this.pps.length)) return;
    if (!this.flow.admit(au.keyframe, this.sink.buffered() > MAX_BUFFERED_BYTES)) {
      this.wantKeyframeSince ??= now;
      return;
    }
    const seq = this.flow.sent(now);
    const bytes = packFrame({
      streamId: this.id, seq, keyframe: au.keyframe, pts: this.deps.pts(),
      width: this.coded?.width ?? this.width, height: this.coded?.height ?? this.height,
      frame: this.target.frame, parameterSets, nals: picture,
    });
    if (this.sink.send(bytes) === 0) {
      this.flow.dropping = true;
      this.wantKeyframeSince ??= now;
      return;
    }
    if (au.keyframe) this.wantKeyframeSince = null;
  }

  ack(seq: number) {
    this.flow.ack(seq, this.deps.now());
  }

  requestKeyframe() {
    this.wantKeyframeSince ??= this.deps.now();
  }

  async tick() {
    if (this.stopped) return;
    const now = this.deps.now();
    if (this.flow.timedOut(now)) return this.end("ack-timeout");
    if (this.wantKeyframeSince !== null && now - this.wantKeyframeSince >= KEYFRAME_WAIT_MS
      && now - this.lastRestart >= RESTART_SPACING_MS && this.flow.inFlight < this.flow.window) {
      this.restart(now);
    }
    if (this.target.wid !== null && now - this.lastWindowCheck >= WINDOW_CHECK_MS) {
      this.lastWindowCheck = now;
      try {
        if (!(await this.deps.windowAlive(this.target.wid))) this.end("window-closed");
      } catch {}
    }
  }

  /** A fresh encoder starts on an IDR. */
  private restart(now: number) {
    this.lastRestart = now;
    const old = this.proc;
    this.spawn();
    if (old) kill(old);
  }

  stop() {
    if (this.stopped) return;
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    if (this.proc) kill(this.proc);
    this.proc = null;
  }

  end(reason: string) {
    if (this.stopped) return;
    this.stop();
    this.sink.event(ENDED_EVENT, { streamId: this.id, reason });
    this.onEnd(this);
  }
}

function kill(proc: EncoderProcess) {
  // SIGINT lets wf-recorder close cleanly; SIGKILL if it lingers.
  try { proc.kill("SIGINT"); } catch {}
  const timer = setTimeout(() => { try { proc.kill("SIGKILL"); } catch {} }, 1000);
  void proc.exited.finally(() => clearTimeout(timer));
}

/** One connection's streams. Closing the connection stops them all. */
export class StreamRegistry {
  readonly streams = new Map<number, StreamSession>();
  private closed = false;

  constructor(private sink: StreamSink, private deps: StreamDeps = defaultStreamDeps) {}

  async handle(method: string, params: Params): Promise<Json> {
    if (method === "capture.stream.start") return this.start(params);
    const streamId = num(params, "streamId");
    if (streamId === undefined) throw RouterError.missingParam("streamId");
    const session = this.streams.get(streamId);
    // Acks still in flight when a stream ends are expected; drop them quietly.
    if (!session && method === "capture.stream.ack") return { ok: false };
    if (!session) throw RouterError.notFound(`stream ${streamId}`);
    if (method === "capture.stream.ack") {
      const seq = num(params, "seq");
      if (seq === undefined) throw RouterError.missingParam("seq");
      session.ack(seq);
    } else if (method === "capture.stream.keyframe") {
      session.requestKeyframe();
    } else if (method === "capture.stream.stop") {
      session.stop();
      this.streams.delete(streamId);
    } else {
      throw RouterError.unknownMethod(method);
    }
    return { ok: true };
  }

  private async start(params: Params): Promise<Json> {
    const codec = str(params, "codec") ?? "h264";
    if (codec !== "h264") throw new RouterError(`capture.stream: unsupported codec ${codec}; this host encodes h264`);
    if (this.streams.size >= MAX_STREAMS_PER_CONNECTION) throw new RouterError(`capture.stream: at most ${MAX_STREAMS_PER_CONNECTION} streams per connection`);
    const maxWidth = clamp(Math.round(num(params, "maxWidth") ?? 1920), 320, 3840);
    const fps = clamp(Math.round(num(params, "fps") ?? 30), 5, 60);
    const target = await captureTarget(params, await this.deps.snapshot(), this.deps.resolveTarget);
    // The connection may have closed while the target resolved.
    if (this.closed) throw new RouterError("capture.stream: connection closed");
    const { width, height } = streamSize(target.pixelWidth, target.frame, maxWidth);
    const id = nextStreamId++ >>> 0;
    const session = new StreamSession(id, target, width, height, fps, this.sink, this.deps, (s) => this.streams.delete(s.id));
    this.streams.set(id, session);
    try {
      session.start();
    } catch (err) {
      session.stop();
      this.streams.delete(id);
      throw new RouterError(`capture.stream: encoder failed to start: ${(err as Error).message}`);
    }
    return { streamId: id, codec: "h264", width, height, frame: target.frame as unknown as Json, display: target.display };
  }

  stopAll() {
    this.closed = true;
    for (const session of this.streams.values()) session.stop();
    this.streams.clear();
  }
}
