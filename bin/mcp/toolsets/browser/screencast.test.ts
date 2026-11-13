import { afterEach, expect, test } from "bun:test";
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BrowserScreencasts, prepareScreencastPresentation, type ScreencastConnection, type ScreencastEncoder, type SourceFrame } from "./screencast.ts";

type Json = Record<string, unknown>;
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
const resources: Array<{ directory: string; recordings: BrowserScreencasts }> = [];

afterEach(async () => {
  for (const { directory, recordings } of resources.splice(0)) {
    recordings.closeSync();
    await rm(directory, { recursive: true, force: true });
  }
});

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>(done => { resolve = done; });
  return { promise, resolve };
}

function connection(options: { start?: Promise<void>; ackError?: Error } = {}) {
  const calls: Array<{ method: string; params?: Json }> = [];
  const listeners = new Set<(event: Json) => void>();
  let closed = 0;
  const session: ScreencastConnection = {
    async call(method, params) {
      calls.push({ method, params });
      if (method === "Page.startScreencast") await options.start;
      else if (method === "Page.screencastFrameAck" && options.ackError) throw options.ackError;
      else if (method !== "Page.stopScreencast" && method !== "Page.screencastFrameAck") throw new Error(method);
      return {};
    },
    on(method, listener) {
      expect(method).toBe("Page.screencastFrame");
      listeners.add(listener);
      return () => { listeners.delete(listener); };
    },
    close() { closed++; },
  };
  return {
    session, calls,
    emit(timestamp: unknown, data = jpeg, sessionId = 7) {
      for (const listener of [...listeners]) listener({ data: data.toString("base64"), metadata: { timestamp }, sessionId });
    },
    get closed() { return closed; },
    get listenerCount() { return listeners.size; },
    get acknowledgements() { return calls.filter(call => call.method === "Page.screencastFrameAck"); },
  };
}

async function setup(options: ConstructorParameters<typeof BrowserScreencasts>[1] = {}) {
  const directory = await mkdtemp(join(tmpdir(), "action-screencast-test-"));
  const encodes: Array<{ directory: string; frames: SourceFrame[]; bytes: Buffer[] }> = [];
  const encode: ScreencastEncoder = async (sourceDirectory, frames, outputPath, signal) => {
    const prepared = await prepareScreencastPresentation(sourceDirectory, frames, signal);
    encodes.push({ directory: sourceDirectory, frames: structuredClone(prepared.frames), bytes: await Promise.all(prepared.frames.map(frame => readFile(join(sourceDirectory, frame.file)))) });
    await writeFile(outputPath, "fake encoder output", { mode: 0o600 });
    return { encodedFrames: prepared.frames.length, duplicateSourceEvents: prepared.duplicateSourceEvents,
      reorderedSourceEvents: prepared.reorderedSourceEvents, presentationOrder: prepared.presentationOrder, encoder: "test-only" };
  };
  const recordings = new BrowserScreencasts(directory, { encode, ...options });
  resources.push({ directory, recordings });
  return { directory, recordings, encodes };
}

test("captures each JPEG and original timestamp, ACKs promptly, and encodes only after stop", async () => {
  const { directory, recordings, encodes } = await setup();
  const c = connection();
  const started = await recordings.start(c.session, "owned-tab", {});
  expect(started.frameRateGuaranteed).toBe(false);
  expect(c.calls[0]).toEqual({ method: "Page.startScreencast", params: { format: "jpeg", quality: 90, maxWidth: 1920, maxHeight: 1080, everyNthFrame: 1 } });
  const timestamps = [1000, 1000.016701, 1000.053917];
  const bytes = [jpeg, Buffer.concat([jpeg, Buffer.from([1])]), Buffer.concat([jpeg, Buffer.from([2, 3])])];
  timestamps.forEach((timestamp, index) => c.emit(timestamp, bytes[index], 70 + index));
  expect(c.acknowledgements.map(call => call.params)).toEqual([{ sessionId: 70 }, { sessionId: 71 }, { sessionId: 72 }]);
  expect(encodes).toHaveLength(0);
  expect(await readdir(directory)).toEqual([]);
  const result = await recordings.stop(String(started.recordingId));
  expect(result.status).toBe("finished");
  expect(encodes).toHaveLength(1);
  expect(encodes[0].frames.map(frame => frame.timestampSeconds)).toEqual(timestamps);
  expect(encodes[0].bytes).toEqual(bytes);
  expect(encodes[0].frames.map(frame => frame.index)).toEqual([0, 1, 2]);
  const manifest = JSON.parse(await readFile(String(result.timestampPath), "utf8"));
  expect(manifest.frames.map((frame: SourceFrame) => frame.timestampSeconds)).toEqual(timestamps);
  expect(manifest.cadence.frames).toBe(3);
  expect(manifest.cadence.maximumIntervalMs).toBeCloseTo(37.216, 4);
  expect((await stat(String(result.timestampPath))).mode & 0o777).toBe(0o600);
  expect((await stat(encodes[0].directory)).mode & 0o777).toBe(0o700);
  expect(await recordings.stop(String(started.recordingId))).toEqual(result);
  expect(c.calls.filter(call => call.method === "Page.stopScreencast")).toHaveLength(1);
  expect(c.listenerCount).toBe(0);
  expect(c.closed).toBe(1);
  expect(recordings.tabId).toBeUndefined();
  c.emit(1001);
  expect(c.acknowledgements).toHaveLength(3);
});

test("rejects another owner without stopping the active capture", async () => {
  const { recordings, encodes } = await setup();
  const first = connection(), second = connection();
  const started = await recordings.start(first.session, "first-tab", {});
  await expect(recordings.start(second.session, "second-tab", {})).rejects.toThrow(/Stop the current/);
  await expect(recordings.stop("not-this-owner")).rejects.toThrow(/Unknown/);
  expect(second.closed).toBe(1);
  expect(first.closed).toBe(0);
  first.emit(1); first.emit(1.02);
  const [a, b] = await Promise.all([recordings.stop(String(started.recordingId)), recordings.stop(String(started.recordingId))]);
  expect(a).toEqual(b);
  expect(encodes).toHaveLength(1);
});

test("presentation sorts source PTS and explicitly deduplicates identical equal-PTS events without changing raw arrival evidence", async () => {
  const { recordings, encodes } = await setup();
  const c = connection();
  const started = await recordings.start(c.session, "tab", {});
  const first = Buffer.concat([jpeg, Buffer.from([1])]);
  const second = Buffer.concat([jpeg, Buffer.from([2])]);
  const arrival = [3, 1, 1, 2];
  const payloads = [jpeg, first, first, second];
  arrival.forEach((timestamp, index) => c.emit(timestamp, payloads[index], 80 + index));
  expect(c.acknowledgements.map(call => call.params?.sessionId)).toEqual([80, 81, 82, 83]);
  const result = await recordings.stop(String(started.recordingId));
  expect(result.encodedFrames).toBe(3);
  expect(result.duplicateSourceEvents).toBe(1);
  expect(result.reorderedSourceEvents).toBe(4);
  expect(result.presentationOrder).toEqual([1, 3, 0]);
  expect(encodes[0].frames.map(frame => frame.timestampSeconds)).toEqual([1, 2, 3]);
  expect(encodes[0].bytes).toEqual([first, second, jpeg]);
  const raw = JSON.parse(await readFile(String(result.timestampPath), "utf8"));
  expect(raw.order).toBe("arrival");
  expect(raw.frames.map((frame: SourceFrame) => frame.timestampSeconds)).toEqual(arrival);
  expect(raw.frames.map((frame: SourceFrame) => frame.index)).toEqual([0, 1, 2, 3]);
  expect(raw.frames.every((frame: SourceFrame) => Number.isFinite(frame.receivedAt))).toBe(true);
  expect(await Promise.all(raw.frames.map((frame: SourceFrame) => readFile(join(String(result.sourceFramesDirectory), frame.file))))).toEqual(payloads);
});

test("different JPEG bytes at equal source PTS fail after retaining every raw arrival", async () => {
  const { directory, recordings, encodes } = await setup();
  const c = connection();
  const started = await recordings.start(c.session, "tab", {});
  const different = Buffer.concat([jpeg, Buffer.from([99])]);
  c.emit(1, jpeg); c.emit(1, different); c.emit(2, jpeg);
  expect(c.acknowledgements).toHaveLength(3);
  await expect(recordings.stop(String(started.recordingId))).rejects.toThrow(/Conflicting JPEG frames share source timestamp/);
  expect(encodes).toHaveLength(0);
  const [sourceDirectory] = await readdir(directory);
  const raw = JSON.parse(await readFile(join(directory, sourceDirectory, "timestamps.json"), "utf8"));
  expect(raw.order).toBe("arrival");
  expect(raw.frames.map((frame: SourceFrame) => frame.timestampSeconds)).toEqual([1, 1, 2]);
  expect(await Promise.all(raw.frames.map((frame: SourceFrame) => readFile(join(directory, sourceDirectory, frame.file))))).toEqual([jpeg, different, jpeg]);
  expect(await Bun.file(join(directory, sourceDirectory, "recording.mp4")).exists()).toBe(false);
  expect(c.listenerCount).toBe(0);
  expect(recordings.tabId).toBeUndefined();
});

test("identical images at distinct timestamps remain distinct presentation frames", async () => {
  const { recordings, encodes } = await setup();
  const c = connection();
  const started = await recordings.start(c.session, "tab", {});
  c.emit(1); c.emit(1.02); c.emit(1.04);
  const result = await recordings.stop(String(started.recordingId));
  expect(result.encodedFrames).toBe(3);
  expect(result.duplicateSourceEvents).toBe(0);
  expect(result.reorderedSourceEvents).toBe(0);
  expect(result.presentationOrder).toEqual([0, 1, 2]);
  expect(encodes[0].bytes).toEqual([jpeg, jpeg, jpeg]);
});

test("graceful shutdown waits for startup and flushes once", async () => {
  const { recordings, encodes } = await setup();
  const gate = deferred(), c = connection({ start: gate.promise });
  const pendingStart = recordings.start(c.session, "tab", {});
  const pendingShutdown = recordings.shutdown();
  try {
    c.emit(1); c.emit(1.02);
    expect(c.calls.filter(call => call.method === "Page.stopScreencast")).toHaveLength(0);
    // Resolve the simulated transport before awaiting shutdown: no circular wait.
    gate.resolve();
    const started = await pendingStart;
    await pendingShutdown;
    expect((await recordings.stop(String(started.recordingId))).reason).toBe("owner-close");
    expect(encodes).toHaveLength(1);
    expect(c.closed).toBe(1);
    expect(c.listenerCount).toBe(0);
  } finally { gate.resolve(); await Promise.allSettled([pendingStart, pendingShutdown]); }
}, 1500);

test("forced close during startup rejects a late successful start and never encodes", async () => {
  const { recordings, encodes } = await setup();
  const gate = deferred(), c = connection({ start: gate.promise });
  const pending = recordings.start(c.session, "tab", {});
  const outcome = pending.then(() => undefined, error => error as Error);
  try {
    recordings.closeSync();
    gate.resolve();
    expect((await outcome)?.message).toMatch(/owner closed during startup/);
    expect(encodes).toHaveLength(0);
    expect(c.listenerCount).toBe(0);
    expect(recordings.tabId).toBeUndefined();
  } finally { gate.resolve(); await Promise.allSettled([pending]); }
}, 1500);

for (const limit of [{ maximumBytes: jpeg.length }, { maximumFrames: 1 }]) {
  test(`storage overflow fails closed without ACKing the rejected frame (${Object.keys(limit)[0]})`, async () => {
    const { directory, recordings, encodes } = await setup(limit);
    const c = connection();
    const started = await recordings.start(c.session, "tab", {});
    c.emit(1); c.emit(1.02);
    await expect(recordings.stop(String(started.recordingId))).rejects.toThrow(/bounded frame storage/);
    expect(c.acknowledgements).toHaveLength(1);
    expect(encodes).toHaveLength(0);
    const [savedDirectory] = await readdir(directory);
    const manifest = JSON.parse(await readFile(join(directory, savedDirectory, "timestamps.json"), "utf8"));
    expect(manifest.frames).toHaveLength(1);
    expect(manifest.frames[0].timestampSeconds).toBe(1);
    expect(manifest.captureFailure).toMatch(/bounded frame storage/);
    expect(await readFile(join(directory, savedDirectory, manifest.frames[0].file))).toEqual(jpeg);
    expect(c.listenerCount).toBe(0);
    expect(recordings.tabId).toBeUndefined();
  });
}

for (const timestamp of [Number.NaN, Number.POSITIVE_INFINITY, undefined]) {
  test(`invalid source timestamp fails visibly (${String(timestamp)})`, async () => {
    const { recordings, encodes } = await setup();
    const c = connection();
    const started = await recordings.start(c.session, "tab", {});
    c.emit(1); c.emit(timestamp);
    await expect(recordings.stop(String(started.recordingId))).rejects.toThrow(/invalid screencast frame/);
    expect(c.acknowledgements).toHaveLength(1);
    expect(encodes).toHaveLength(0);
    expect(c.listenerCount).toBe(0);
  });
}

test("invalid JPEG and failed ACK cannot produce a successful artifact", async () => {
  for (const ackError of [undefined, new Error("ACK transport lost")]) {
    const { recordings, encodes } = await setup();
    const c = connection({ ackError });
    const started = await recordings.start(c.session, "tab", {});
    if (ackError) { c.emit(1); await Promise.resolve(); }
    else c.emit(1, Buffer.from("not a jpeg"));
    await expect(recordings.stop(String(started.recordingId))).rejects.toThrow(ackError ? /ACK transport lost/ : /invalid JPEG/);
    expect(encodes).toHaveLength(0);
    expect(c.listenerCount).toBe(0);
  }
});

test("duration expiry stops capture, detaches events, and retains the finished result", async () => {
  const { recordings, encodes } = await setup();
  const c = connection();
  const started = await recordings.start(c.session, "tab", { maxDurationMs: 1000 });
  c.emit(1); c.emit(1.02);
  await Bun.sleep(1100);
  const result = await recordings.stop(String(started.recordingId));
  expect(result.reason).toBe("duration-limit");
  expect(encodes).toHaveLength(1);
  expect(c.listenerCount).toBe(0);
  expect(recordings.tabId).toBeUndefined();
}, 2500);

test("encoder failure retains original evidence but is never reported as finished", async () => {
  const { directory, recordings } = await setup({ encode: async () => { throw new Error("hardware encoder unavailable"); } });
  const c = connection();
  const started = await recordings.start(c.session, "tab", {});
  c.emit(1); c.emit(1.02);
  await expect(recordings.stop(String(started.recordingId))).rejects.toThrow(/hardware encoder unavailable/);
  await expect(recordings.stop(String(started.recordingId))).rejects.toThrow(/hardware encoder unavailable/);
  const [sourceDirectory] = await readdir(directory);
  expect((await readdir(join(directory, sourceDirectory))).sort()).toEqual(["000000.jpg", "000001.jpg", "timestamps.json"]);
  expect(c.listenerCount).toBe(0);
  expect(recordings.tabId).toBeUndefined();
});

test("invalid start options close the supplied connection without reserving ownership", async () => {
  const { recordings } = await setup();
  const c = connection();
  await expect(recordings.start(c.session, "tab", { maxDurationMs: -1 })).rejects.toThrow(/maxDurationMs/);
  expect(c.closed).toBe(1);
  expect(c.listenerCount).toBe(0);
  expect(c.calls).toEqual([]);
  expect(recordings.tabId).toBeUndefined();
});

for (const reason of ["deadline", "owner-close"] as const) {
  test(`${reason} aborts finalization and removes output from an encoder that settles late`, async () => {
    const entered = deferred(), release = deferred(), written = deferred();
    let encoderSignal: AbortSignal | undefined;
    let outputPath = "";
    const { directory, recordings } = await setup({
      finishTimeoutMs: reason === "deadline" ? 100 : 1000,
      encode: async (_directory, _frames, path, signal) => {
        encoderSignal = signal;
        outputPath = path;
        entered.resolve();
        await release.promise;
        // Model a worker that settles despite cancellation. Its caller must
        // remove the late artifact rather than publish a finished result.
        await writeFile(path, "late output", { mode: 0o600 });
        written.resolve();
        return { encodedFrames: 2 };
      },
    });
    const c = connection();
    const started = await recordings.start(c.session, "tab", {});
    c.emit(1); c.emit(1.02);
    const stopping = recordings.stop(String(started.recordingId));
    const outcome = stopping.then(() => undefined, error => error as Error);
    try {
      await entered.promise;
      if (reason === "owner-close") recordings.closeSync();
      expect((await outcome)?.message).toMatch(reason === "deadline" ? /timed out/ : /owner closed/);
      expect(encoderSignal?.aborted).toBe(true);
      release.resolve();
      await written.promise;
      await Bun.sleep(40);
      expect(await Bun.file(outputPath).exists()).toBe(false);
      const [sourceDirectory] = await readdir(directory);
      expect(await Bun.file(join(directory, sourceDirectory, "timestamps.json")).exists()).toBe(true);
      expect(c.listenerCount).toBe(0);
      expect(recordings.tabId).toBeUndefined();
      await expect(recordings.stop(String(started.recordingId))).rejects.toThrow(reason === "deadline" ? /timed out/ : /owner closed/);
    } finally {
      release.resolve();
      await Promise.allSettled([stopping, written.promise]);
    }
  }, 1500);
}
