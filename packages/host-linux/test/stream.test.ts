import { describe, expect, test } from "bun:test";
import {
  AccessUnitSplitter, FlowControl, NalScanner, StreamRegistry, bitrateFor, defaultStreamDeps, encoderCommand, nalType, packFrame,
  spsSize, splitParameterSets, streamSize, type EncoderProcess, type StreamDeps,
} from "../src/stream.ts";

const bytes = (...v: number[]) => Uint8Array.from(v);
const annexB = (...nals: Uint8Array[]) => {
  const parts: number[] = [];
  nals.forEach((nal, i) => parts.push(...(i % 2 ? [0, 0, 1] : [0, 0, 0, 1]), ...nal));
  return Uint8Array.from(parts);
};

const SPS = bytes(0x67, 0x42, 0xc0, 0x1e, 0xab);
const PPS = bytes(0x68, 0xce, 0x3c, 0x80);
const SEI = bytes(0x06, 0x05, 0x01, 0x80);
const IDR_A = bytes(0x65, 0x88, 0x84, 0x00, 0x21); // first_mb_in_slice 0
const IDR_B = bytes(0x65, 0x08, 0x84, 0x21); // a later slice of the same picture
const P1 = bytes(0x41, 0x9a, 0x02);
const P2 = bytes(0x41, 0x9b, 0x03, 0x00, 0x00, 0x03, 0x01);
const AUD = bytes(0x09, 0xf0);

describe("Annex B", () => {
  test("scanner finds 3- and 4-byte start codes, whatever the chunking", () => {
    const stream = annexB(SPS, PPS, IDR_A, P1);
    const whole = new NalScanner();
    const all = [...whole.push(stream), ...whole.flush()];
    expect(all).toEqual([SPS, PPS, IDR_A, P1]);
    const bytewise = new NalScanner();
    const pieces: Uint8Array[] = [];
    for (const b of stream) pieces.push(...bytewise.push(bytes(b)));
    pieces.push(...bytewise.flush());
    expect(pieces).toEqual(all);
  });

  test("splitter groups parameter sets with the IDR and keeps multi-slice pictures whole", () => {
    const splitter = new AccessUnitSplitter();
    const stream = annexB(SPS, PPS, SEI, IDR_A, IDR_B, P1, P2);
    const aus = [...splitter.push(stream.subarray(0, 17)), ...splitter.push(stream.subarray(17)), ...splitter.flush()];
    expect(aus.map((a) => a.keyframe)).toEqual([true, false, false]);
    expect(aus[0].nals).toEqual([SPS, PPS, SEI, IDR_A, IDR_B]);
    expect(aus[1].nals).toEqual([P1]);
    expect(aus[2].nals).toEqual([P2]);
  });

  test("an AUD starts a unit and is dropped", () => {
    const splitter = new AccessUnitSplitter();
    const aus = [...splitter.push(annexB(AUD, SPS, PPS, IDR_A, AUD, P1, AUD, P2)), ...splitter.flush()];
    expect(aus.map((a) => a.nals.map(nalType))).toEqual([[7, 8, 5], [1], [1]]);
  });

  test("a unit is cut as soon as the next one's head arrives", () => {
    const splitter = new AccessUnitSplitter();
    expect(splitter.push(annexB(SPS, PPS, IDR_A))).toEqual([]);
    const p1 = annexB(P1); // 4-byte start code
    expect(splitter.push(p1.subarray(0, 5))).toEqual([]);
    const cut = splitter.push(p1.subarray(5, 6));
    expect(cut.map((a) => a.nals)).toEqual([[SPS, PPS, IDR_A]]);
    expect(splitter.push(p1.subarray(6))).toEqual([]);
    expect(splitter.push(bytes(0, 0, 1, 0x41)).length).toBe(0); // slice head not in yet
    expect(splitter.push(bytes(0x9a)).map((a) => a.nals)).toEqual([[P1]]);
  });

  test("going quiet ends a trailing slice and the splitter carries on", () => {
    const splitter = new AccessUnitSplitter();
    expect(splitter.push(annexB(SPS, PPS, IDR_A))).toEqual([]);
    expect(splitter.flushPending().map((a) => a.nals)).toEqual([[SPS, PPS, IDR_A]]);
    expect(splitter.flushPending()).toEqual([]);
    expect(splitter.push(annexB(SPS))).toEqual([]);
    expect(splitter.flushPending()).toEqual([]); // not a slice: wait for one
    expect(splitter.push(annexB(P1, P2)).map((a) => a.nals)).toEqual([[SPS, P1]]);
    expect(splitter.flushPending().map((a) => a.nals)).toEqual([[P2]]);
  });

  test("a later slice of the same picture doesn't cut it", () => {
    const splitter = new AccessUnitSplitter();
    expect(splitter.push(annexB(SPS, PPS, IDR_A, IDR_B))).toEqual([]);
    expect(splitter.flush().map((a) => a.nals)).toEqual([[SPS, PPS, IDR_A, IDR_B]]);
  });

  test("parameter sets come out of the picture", () => {
    const { sps, pps, picture } = splitParameterSets({ keyframe: true, nals: [SPS, PPS, SEI, IDR_A] });
    expect(sps).toEqual([SPS]);
    expect(pps).toEqual([PPS]);
    expect(picture).toEqual([SEI, IDR_A]);
  });
});

describe("wire frame", () => {
  test("header and payload, byte for byte", () => {
    const out = packFrame({
      streamId: 0x01020304, seq: 7, keyframe: true, pts: 0x0102030405060708n, width: 1920, height: 1080,
      frame: { x: -1.5, y: 25, w: 1280, h: 720 }, parameterSets: [SPS, PPS], nals: [IDR_A],
    });
    const expected = [
      0x4c, 0x56, 0x46, 0x31, // LVF1
      0x01, 0x02, 0x03, 0x04, // streamId
      0x00, 0x00, 0x00, 0x07, // seq
      0x03, 0x01, 0x00, 0x00, // flags (key + sets), codec h264, reserved
      0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // pts
      0x00, 0x00, 0x07, 0x80, // width 1920
      0x00, 0x00, 0x04, 0x38, // height 1080
      0xbf, 0xc0, 0x00, 0x00, // -1.5f
      0x41, 0xc8, 0x00, 0x00, // 25f
      0x44, 0xa0, 0x00, 0x00, // 1280f
      0x44, 0x34, 0x00, 0x00, // 720f
      0x00, 0x02, // two parameter sets
      0x00, 0x05, ...SPS,
      0x00, 0x04, ...PPS,
      0x00, 0x00, 0x00, 0x05, ...IDR_A,
    ];
    expect([...out]).toEqual(expected);
  });

  test("a delta frame has no parameter-set block", () => {
    const out = packFrame({
      streamId: 1, seq: 2, keyframe: false, pts: 1n, width: 2, height: 2,
      frame: { x: 0, y: 0, w: 2, h: 2 }, parameterSets: [], nals: [P1, P2],
    });
    expect(out[12]).toBe(0);
    expect([...out.subarray(48)]).toEqual([0, 0, 0, 3, ...P1, 0, 0, 0, 7, ...P2]);
  });
});

describe("encoder command", () => {
  test("display, software", () => {
    const { command, args } = encoderCommand({ output: "DP-1", width: 1920, height: 1080, fps: 30, encoder: "software" });
    expect(command).toBe("wf-recorder");
    expect(args).toEqual([
      "-o", "DP-1", "-D", "-r", "30",
      "-c", "libx264", "-x", "yuv420p", "-F", "scale=1920:1080:in_range=full:out_range=full:out_color_matrix=bt709",
      "-p", "color_range=pc", "-p", "colorspace=bt709", "-p", "color_primaries=bt709", "-p", "color_trc=iec61966-2-1",
      "-p", "preset=ultrafast", "-p", "tune=zerolatency", "-p", "maxrate=6220800", "-p", "bufsize=3110400",
      "-p", "profile=main", "-p", "bf=0", "-p", "g=60", "-p", "b=6220800",
      "-m", "h264", "-f", "pipe:1",
    ]);
  });

  test("region, VAAPI", () => {
    const { args } = encoderCommand({ region: { x: 10.4, y: 20, w: 800, h: 600 }, width: 800, height: 600, fps: 60, encoder: "vaapi", device: "/dev/dri/renderD129" });
    expect(args).toEqual([
      "-g", "10,20 800x600", "-D", "-r", "60",
      "-c", "h264_vaapi", "-d", "/dev/dri/renderD129", "-F", "scale_vaapi=w=800:h=600:format=nv12",
      "-p", "profile=main", "-p", "bf=0", "-p", "g=120", "-p", "b=2880000",
      "-m", "h264", "-f", "pipe:1",
    ]);
  });

  test("size: capped to maxWidth, even, aspect kept", () => {
    expect(streamSize(3440, { x: 0, y: 0, w: 3440, h: 1440 }, 1920)).toEqual({ width: 1920, height: 802 });
    expect(streamSize(2560, { x: 0, y: 0, w: 1280, h: 801 }, 3840)).toEqual({ width: 2560, height: 1602 });
    expect(streamSize(301, { x: 0, y: 0, w: 301, h: 201 }, 1920)).toEqual({ width: 300, height: 200 });
  });

  test("bitrate: 0.1 bit per pixel per frame, capped", () => {
    expect(bitrateFor(1920, 1080, 30)).toBe(6_220_800);
    expect(bitrateFor(3840, 2160, 60)).toBe(20_000_000);
    expect(bitrateFor(320, 200, 5)).toBe(500_000);
  });
});

describe("flow control", () => {
  test("waits for the first keyframe", () => {
    const flow = new FlowControl();
    expect(flow.admit(false)).toBe(false);
    expect(flow.admit(true)).toBe(true);
    expect(flow.admit(false)).toBe(true);
  });

  test("at 4 unacked it drops until a keyframe, even after acks", () => {
    const flow = new FlowControl();
    expect(flow.admit(true)).toBe(true);
    flow.sent(0);
    for (let i = 0; i < 3; i++) {
      expect(flow.admit(false)).toBe(true);
      flow.sent(0);
    }
    expect(flow.inFlight).toBe(4);
    expect(flow.admit(false)).toBe(false);
    expect(flow.admit(true)).toBe(false); // still full
    flow.ack(4, 10);
    expect(flow.inFlight).toBe(0);
    expect(flow.admit(false)).toBe(false); // chain broken
    expect(flow.admit(true)).toBe(true);
    flow.sent(20);
    expect(flow.admit(false)).toBe(true);
  });

  test("a backed-up socket breaks the chain too", () => {
    const flow = new FlowControl();
    flow.admit(true);
    flow.sent(0);
    expect(flow.admit(false, true)).toBe(false);
    expect(flow.admit(false)).toBe(false);
  });

  test("acks are cumulative; stale and future ones are ignored", () => {
    const flow = new FlowControl();
    flow.admit(true);
    flow.sent(0); flow.sent(0); flow.sent(0);
    flow.ack(9, 1);
    expect(flow.lastAcked).toBe(0);
    flow.ack(2, 1);
    flow.ack(1, 1);
    expect(flow.lastAcked).toBe(2);
  });

  test("times out after 3 s of outstanding frames without an ack", () => {
    const flow = new FlowControl();
    expect(flow.timedOut(1e9)).toBe(false);
    flow.admit(true);
    flow.sent(1000);
    expect(flow.timedOut(3999)).toBe(false);
    flow.sent(2000);
    flow.ack(1, 3500);
    expect(flow.timedOut(6000)).toBe(false);
    expect(flow.timedOut(6500)).toBe(true);
    flow.ack(2, 6500);
    expect(flow.timedOut(1e9)).toBe(false);
  });
});

describe("session", () => {
  function fakeEncoder() {
    let push!: (chunk: Uint8Array) => void;
    let close!: () => void;
    let exit!: (code: number) => void;
    const proc: EncoderProcess & { killed: (string | number | undefined)[] } = {
      stdout: new ReadableStream({ start(c) { push = (b) => c.enqueue(b); close = () => c.close(); } }),
      stderr: new ReadableStream({ start(c) { c.close(); } }),
      exited: new Promise((r) => { exit = r; }),
      killed: [],
      kill(signal) { this.killed.push(signal); },
    };
    return { proc, push: (b: Uint8Array) => push(b), close: () => close(), exit: (code: number) => exit(code) };
  }

  function harness(opts: { vaapi?: boolean; buffered?: () => number; tickMs?: number; onSend?: (bytes: Uint8Array, at: number) => void } = {}) {
    const sent: Uint8Array[] = [];
    const events: { name: string; data: any }[] = [];
    const encoders: ReturnType<typeof fakeEncoder>[] = [];
    const commands: string[][] = [];
    let clock = 0;
    const deps: StreamDeps = {
      snapshot: async () => ({
        windows: [], clients: [], focused: null,
        monitors: [{ name: "DP-1", focused: true }],
        displays: [{ displayIndex: 0, displayId: "DP-1", name: "Panel", frame: { x: 0, y: 0, w: 1280, h: 800 }, scale: 2 }],
      }) as any,
      resolveTarget: async () => { throw new Error("no windows"); },
      spawn: (cmd) => {
        commands.push(cmd.args);
        const e = fakeEncoder();
        encoders.push(e);
        return e.proc;
      },
      now: () => clock,
      pts: () => BigInt(clock * 1000),
      windowAlive: async () => true,
      vaapiDevice: () => (opts.vaapi ? "/dev/dri/renderD128" : null),
      tickMs: opts.tickMs ?? 1e9,
      quietMs: 50,
    };
    const registry = new StreamRegistry({
      send: (b) => { sent.push(b); opts.onSend?.(b, clock); return b.length; },
      buffered: opts.buffered ?? (() => 0),
      event: (name, data) => events.push({ name, data }),
    }, deps);
    return { registry, sent, events, encoders, commands, setClock: (t: number) => { clock = t; } };
  }

  const settle = () => new Promise((r) => setTimeout(r, 5));

  test("start returns the contract shape and frames carry it", async () => {
    const h = harness();
    const result = await h.registry.handle("capture.stream.start", { maxWidth: 1920, fps: 30 }) as any;
    expect(result).toMatchObject({ codec: "h264", width: 1920, height: 1200, frame: { x: 0, y: 0, w: 1280, h: 800 }, display: { index: 0, name: "Panel" } });
    expect(h.commands[0].slice(0, 5)).toEqual(["-o", "DP-1", "-D", "-r", "30"]);
    h.encoders[0].push(annexB(SPS, PPS, IDR_A, P1, P2));
    await settle();
    expect(h.sent.length).toBe(2); // P2 heads the next unit, still arriving
    const view = new DataView(h.sent[0].buffer);
    expect(view.getUint32(4)).toBe(result.streamId);
    expect(view.getUint32(8)).toBe(1);
    expect(h.sent[0][12]).toBe(3);
    expect(h.sent[1][12]).toBe(0);
    expect(new DataView(h.sent[1].buffer).getUint32(8)).toBe(2);
    expect(view.getFloat32(40)).toBe(1280);
    h.registry.stopAll();
    expect(h.encoders[0].proc.killed).toEqual(["SIGINT"]);
  });

  test("a lone IDR on a still screen goes out once stdout is quiet", async () => {
    const h = harness();
    await h.registry.handle("capture.stream.start", {});
    h.encoders[0].push(annexB(SPS, PPS, IDR_A));
    await settle();
    expect(h.sent.length).toBe(0);
    await new Promise((r) => setTimeout(r, 80));
    expect(h.sent.length).toBe(1);
    expect(h.sent[0][12]).toBe(3);
    h.registry.stopAll();
  });

  test("a connection that closes mid-start spawns no encoder", async () => {
    const h = harness();
    const pending = h.registry.handle("capture.stream.start", {});
    h.registry.stopAll();
    await expect(pending).rejects.toThrow("connection closed");
    expect(h.encoders.length).toBe(0);
    expect(h.registry.streams.size).toBe(0);
  });

  test("ack timeout ends the stream with an event", async () => {
    const h = harness();
    const { streamId } = await h.registry.handle("capture.stream.start", {}) as any;
    h.encoders[0].push(annexB(SPS, PPS, IDR_A, P1));
    await settle();
    const session = h.registry.streams.get(streamId)!;
    h.setClock(3000);
    await session.tick();
    expect(h.events).toEqual([{ name: "capture.stream.ended", data: { streamId, reason: "ack-timeout" } }]);
    expect(h.registry.streams.size).toBe(0);
  });

  test("a transient startup burst waits for acks without breaking the decode chain", async () => {
    const h = harness();
    const { streamId } = await h.registry.handle("capture.stream.start", { fps: 60 }) as any;
    const session = h.registry.streams.get(streamId)!;
    session.onAccessUnit({ keyframe: true, nals: [SPS, PPS, IDR_A] });
    for (let i = 1; i < 16; i++) {
      h.setClock(i * 4);
      session.onAccessUnit({ keyframe: false, nals: [bytes(0x41, 0x80, i)] });
    }
    expect(h.sent.length).toBe(12);
    expect(session.flow.inFlight).toBe(12);
    h.setClock(120);
    session.ack(12);
    expect(h.sent.length).toBe(16);
    expect(session.flow.inFlight).toBe(4);
    expect(session.flow.dropping).toBe(false);
    expect(h.sent.map((b) => new DataView(b.buffer).getUint32(8))).toEqual(Array.from({ length: 16 }, (_, i) => i + 1));
    expect(h.sent.slice(1).map((b) => b[b.length - 1])).toEqual(Array.from({ length: 15 }, (_, i) => i + 1));
    // Waiting must not rewrite a frame's capture/encode timestamp.
    expect(new DataView(h.sent[12].buffer).getBigUint64(16)).toBe(48_000n);
    h.registry.stopAll();
  });

  test("the ACK window follows frame rate within the bounded frame budget", async () => {
    for (const [fps, window] of [[5, 4], [20, 4], [30, 6], [60, 12]]) {
      const h = harness();
      const { streamId } = await h.registry.handle("capture.stream.start", { fps }) as any;
      expect(h.registry.streams.get(streamId)!.flow.window).toBe(window);
      h.registry.stopAll();
    }
  });

  for (const ackMs of [80, 120]) test(`60 fps stays continuous with sustained ${ackMs} ms ACKs`, async () => {
    const acks: { seq: number; at: number }[] = [];
    const h = harness({ onSend: (bytes, at) => acks.push({ seq: new DataView(bytes.buffer).getUint32(8), at: at + ackMs }) });
    const { streamId } = await h.registry.handle("capture.stream.start", { fps: 60 }) as any;
    const session = h.registry.streams.get(streamId)!;
    let maxFlight = 0;
    const deliverAcks = (until: number) => {
      while (acks.length && acks[0].at <= until) {
        const ack = acks.shift()!;
        h.setClock(ack.at);
        session.ack(ack.seq);
      }
    };
    // Five seconds is long enough for the old four-frame window to exhaust
    // its pending queue, drop references and restart waiting for an IDR.
    for (let i = 0; i < 300; i++) {
      const at = Math.round(i * 1000 / 60);
      deliverAcks(at);
      h.setClock(at);
      session.onAccessUnit(i === 0 ? { keyframe: true, nals: [SPS, PPS, IDR_A] } : { keyframe: false, nals: [P1] });
      maxFlight = Math.max(maxFlight, session.flow.inFlight);
      if (i % 3 === 0) await session.tick();
    }
    deliverAcks(Infinity);
    expect(h.sent.length).toBe(300);
    expect(h.sent.map((b) => new DataView(b.buffer).getUint32(8))).toEqual(Array.from({ length: 300 }, (_, i) => i + 1));
    expect(h.sent.filter((b) => b[12] & 1).length).toBe(1);
    expect(maxFlight).toBeGreaterThan(4);
    expect(maxFlight).toBeLessThanOrEqual(12);
    expect(session.flow.inFlight).toBe(0);
    expect(session.flow.dropping).toBe(false);
    expect(h.encoders.length).toBe(1);
    expect(h.events).toEqual([]);
    h.registry.stopAll();
  });

  test("a full pending queue discards its dependent chain and recovers only at an IDR", async () => {
    const h = harness();
    const { streamId } = await h.registry.handle("capture.stream.start", { fps: 60 }) as any;
    const session = h.registry.streams.get(streamId)!;
    session.onAccessUnit({ keyframe: true, nals: [SPS, PPS, IDR_A] });
    // Twelve sent plus at most 200 ms (12 frames at 60 fps) waiting.
    for (let i = 0; i < 24; i++) session.onAccessUnit({ keyframe: false, nals: [P1] });
    session.ack(12);
    expect(h.sent.length).toBe(12);
    session.onAccessUnit({ keyframe: false, nals: [P2] });
    expect(h.sent.length).toBe(12);
    session.onAccessUnit({ keyframe: true, nals: [SPS, PPS, IDR_A] });
    expect(h.sent.length).toBe(13);
    expect(h.sent[12][12] & 1).toBe(1);
    h.registry.stopAll();
  });

  test("the default timer drains a recovered socket before pending frames expire", async () => {
    let buffered = 4 * 1024 * 1024 + 1;
    const h = harness({ buffered: () => buffered, tickMs: defaultStreamDeps.tickMs });
    const { streamId } = await h.registry.handle("capture.stream.start", { fps: 60 }) as any;
    const session = h.registry.streams.get(streamId)!;
    session.onAccessUnit({ keyframe: true, nals: [SPS, PPS, IDR_A] });
    session.onAccessUnit({ keyframe: false, nals: [P1] });
    expect(h.sent.length).toBe(0);
    buffered = 0;
    h.setClock(defaultStreamDeps.tickMs);
    await new Promise((resolve) => setTimeout(resolve, defaultStreamDeps.tickMs + 10));
    expect(h.sent.length).toBe(2);
    expect(h.sent.map((b) => b[12] & 1)).toEqual([1, 0]);
    expect(session.flow.inFlight).toBe(2);
    expect(session.flow.dropping).toBe(false);
    await session.tick();
    expect(h.sent.length).toBe(2);
    h.registry.stopAll();
  });

  test("frames waiting over 200 ms are never sent after a late ack", async () => {
    const h = harness();
    const { streamId } = await h.registry.handle("capture.stream.start", { fps: 60 }) as any;
    const session = h.registry.streams.get(streamId)!;
    session.onAccessUnit({ keyframe: true, nals: [SPS, PPS, IDR_A] });
    for (let i = 0; i < 13; i++) session.onAccessUnit({ keyframe: false, nals: [P1] });
    h.setClock(201);
    session.ack(12);
    expect(h.sent.length).toBe(12);
    expect(session.flow.dropping).toBe(true);
    session.onAccessUnit({ keyframe: true, nals: [SPS, PPS, IDR_A] });
    expect(h.sent.length).toBe(13);
    h.registry.stopAll();
  });

  test("the pending byte budget breaks an oversized chain instead of retaining it", async () => {
    const h = harness();
    const { streamId } = await h.registry.handle("capture.stream.start", { fps: 60 }) as any;
    const session = h.registry.streams.get(streamId)!;
    session.onAccessUnit({ keyframe: true, nals: [SPS, PPS, IDR_A] });
    for (let i = 0; i < 11; i++) session.onAccessUnit({ keyframe: false, nals: [P1] });
    const large = new Uint8Array(3 * 1024 * 1024);
    large.set(P1);
    session.onAccessUnit({ keyframe: false, nals: [large] });
    session.onAccessUnit({ keyframe: false, nals: [large] });
    session.ack(12);
    expect(h.sent.length).toBe(12);
    expect(session.flow.dropping).toBe(true);
    h.registry.stopAll();
  });

  test("a stalled keyframe wait restarts the encoder", async () => {
    const h = harness();
    const { streamId } = await h.registry.handle("capture.stream.start", {}) as any;
    const session = h.registry.streams.get(streamId)!;
    await h.registry.handle("capture.stream.keyframe", { streamId });
    h.setClock(1500);
    await session.tick();
    expect(h.encoders.length).toBe(1); // too soon after start
    h.setClock(2500);
    await session.tick();
    expect(h.encoders.length).toBe(2);
    expect(h.encoders[0].proc.killed).toEqual(["SIGINT"]);
    h.registry.stopAll();
  });

  test("VAAPI that dies before a frame falls back to software", async () => {
    const h = harness({ vaapi: true });
    await h.registry.handle("capture.stream.start", {});
    expect(h.commands[0]).toContain("h264_vaapi");
    h.encoders[0].exit(1);
    await settle();
    expect(h.commands[1]).toContain("libx264");
    expect(h.events).toEqual([]);
    h.registry.stopAll();
  });

  test("an encoder exit mid-stream ends it", async () => {
    const h = harness();
    const { streamId } = await h.registry.handle("capture.stream.start", {}) as any;
    h.encoders[0].push(annexB(SPS, PPS, IDR_A, P1));
    await settle();
    h.encoders[0].exit(2);
    await settle();
    expect(h.events[0]).toEqual({ name: "capture.stream.ended", data: { streamId, reason: "encoder-failed: exited (2)" } });
  });

  test("only h264, and unknown streams are errors except for late acks", async () => {
    const h = harness();
    await expect(h.registry.handle("capture.stream.start", { codec: "hevc" })).rejects.toThrow("unsupported codec");
    await expect(h.registry.handle("capture.stream.keyframe", { streamId: 999 })).rejects.toThrow("stream 999");
    expect(await h.registry.handle("capture.stream.ack", { streamId: 999, seq: 1 })).toEqual({ ok: false });
  });
});

// Real x264 output, when this machine has ffmpeg with libx264: split, pack,
// rebuild Annex B from the wire frames and have ffmpeg decode every picture.
const ffmpeg = Bun.which("ffmpeg");
const ffprobe = Bun.which("ffprobe");
const hasX264 = ffmpeg !== null && Bun.spawnSync([ffmpeg, "-hide_banner", "-encoders"]).stdout.toString().includes("libx264");
describe.skipIf(!hasX264)("x264 round trip", () => {
  test("the software command preserves desktop contrast and colors", () => {
    const colors = [
      [0, 0, 0], [255, 255, 255], [128, 128, 128],
      [255, 0, 0], [0, 255, 0], [0, 0, 255],
      [255, 255, 0], [255, 0, 255], [0, 255, 255],
      [32, 32, 32], [64, 64, 64], [192, 192, 192],
    ];
    const patchWidth = 32, width = colors.length * patchWidth, height = 64;
    const rgb = new Uint8Array(width * 2 * height * 2 * 4);
    for (let y = 0; y < height * 2; y++) for (let x = 0; x < width * 2; x++) {
      rgb.set(colors[Math.floor(x / (patchWidth * 2))], (y * width * 2 + x) * 4);
    }
    const { args } = encoderCommand({ output: "DP-1", width, height, fps: 30, encoder: "software" });
    const option = (name: string) => args[args.indexOf(name) + 1];
    const codecOptions: string[] = [];
    // wf-recorder sets its encoder to full range independently of the filter.
    // Keep these stages separate: ffmpeg's combined CLI graph can otherwise
    // negotiate that tag back into the scaler and conceal the original bug.
    const frameColorOptions = new Map<string, string>([["color_range", "pc"]]);
    for (let i = 0; i < args.length; i++) if (args[i] === "-p") {
      const [key, value] = args[++i].split("=");
      codecOptions.push(`-${key}:v`, value);
      if (["color_range", "colorspace", "color_primaries", "color_trc"].includes(key)) frameColorOptions.set(key, value);
    }
    const run = (command: string, options: string[], stdin: Uint8Array) => {
      const result = Bun.spawnSync([command, "-loglevel", "error", ...options], { stdin });
      expect(result.exitCode, result.stderr.toString()).toBe(0);
      return result.stdout;
    };
    const yuv = run(ffmpeg!, [
      "-f", "rawvideo", "-pixel_format", "rgb0", "-video_size", `${width * 2}x${height * 2}`, "-i", "-",
      "-vf", `${option("-F")},format=${option("-x")}`, "-frames:v", "1", "-f", "rawvideo", "-",
    ], rgb);
    // Raw YUV has no metadata. Give ffmpeg the codec context's actual tags so
    // its CLI neither converts the samples again nor overrides them as unknown.
    const encoded = run(ffmpeg!, [
      "-f", "rawvideo", "-pixel_format", option("-x"), "-video_size", `${width}x${height}`, "-framerate", option("-r"),
      ...[...frameColorOptions].flatMap(([key, value]) => [`-${key}`, value]), "-i", "-",
      "-frames:v", "1", "-c:v", option("-c"), "-color_range:v", "pc", ...codecOptions, "-f", "h264", "-",
    ], yuv);
    const decoded = run(ffmpeg!, [
      "-f", "h264", "-i", "-", "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-",
    ], encoded);
    expect(decoded.length).toBe(width * height * 3);
    for (const [index, color] of colors.entries()) {
      const center = ((height / 2) * width + index * patchWidth + patchWidth / 2) * 3;
      for (let channel = 0; channel < 3; channel++) {
        expect(Math.abs(decoded[center + channel] - color[channel]), `patch ${color}, channel ${channel}`).toBeLessThanOrEqual(4);
      }
    }
    if (ffprobe) {
      const metadata = JSON.parse(run(ffprobe, [
        "-show_entries", "stream=color_range,color_space,color_transfer,color_primaries", "-of", "json", "-f", "h264", "-i", "-",
      ], encoded).toString());
      expect(metadata.streams[0]).toMatchObject({
        color_range: "pc", color_space: "bt709", color_transfer: "iec61966-2-1", color_primaries: "bt709",
      });
    }
  });

  const encode = (extra: string) => Bun.spawnSync([
    ffmpeg!, "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=322x180:rate=30", "-frames:v", "12",
    "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-bf", "0", "-g", "5",
    "-x264-params", extra, "-pix_fmt", "yuv420p", "-f", "h264", "-",
  ]).stdout;

  for (const extra of ["sliced-threads=1:slices=4", "aud=1"]) {
    test(extra, () => {
      const stream = new Uint8Array(encode(extra));
      expect(stream.length).toBeGreaterThan(100);
      const splitter = new AccessUnitSplitter();
      const aus = [];
      for (let i = 0; i < stream.length; i += 997) aus.push(...splitter.push(stream.subarray(i, i + 997)));
      aus.push(...splitter.flush());
      expect(aus.length).toBe(12);
      expect(aus.map((a, i) => a.keyframe === (i % 5 === 0))).toEqual(Array(12).fill(true));
      if (extra.includes("sliced")) expect(aus[3].nals.filter((n) => nalType(n) === 1).length).toBeGreaterThan(1);

      const sps = splitParameterSets(aus[0]).sps[0];
      expect(spsSize(sps)).toEqual({ width: 322, height: 180 });

      const rebuilt: number[] = [];
      aus.forEach((au, i) => {
        const { sps, pps, picture } = splitParameterSets(au);
        const wire = packFrame({
          streamId: 1, seq: i + 1, keyframe: au.keyframe, pts: BigInt(i), width: 322, height: 180,
          frame: { x: 0, y: 0, w: 322, h: 180 }, parameterSets: au.keyframe ? [...sps, ...pps] : [], nals: picture,
        });
        const view = new DataView(wire.buffer);
        let at = 48;
        if (wire[12] & 2) {
          const count = view.getUint16(at); at += 2;
          for (let k = 0; k < count; k++) {
            const len = view.getUint16(at); at += 2;
            rebuilt.push(0, 0, 0, 1, ...wire.subarray(at, at + len)); at += len;
          }
        }
        while (at < wire.length) {
          const len = view.getUint32(at); at += 4;
          rebuilt.push(0, 0, 0, 1, ...wire.subarray(at, at + len)); at += len;
        }
      });
      const decoded = Bun.spawnSync([ffmpeg!, "-loglevel", "error", "-f", "h264", "-i", "-", "-f", "framemd5", "-"], { stdin: Uint8Array.from(rebuilt) });
      expect(decoded.stderr.toString()).toBe("");
      expect(decoded.stdout.toString().split("\n").filter((l) => l && !l.startsWith("#")).length).toBe(12);
    });
  }
});
