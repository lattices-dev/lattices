import { expect, test } from "bun:test";
import { mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { withDeadline } from "./transport.ts";
import { BrowserRecordings, frameSchedulingFlags, frameSchedulingFromCommand, parseFrameScheduling, parseRecordingOptions, supportsScreenRecording, type RecordingConnection } from "./recording.ts";

test("scheduling is explicit, bounded to explicit policies, and does not assert a rate", () => {
  expect(parseFrameScheduling(undefined)).toBeUndefined();
  expect(frameSchedulingFlags(parseFrameScheduling("uncapped"))).toEqual(["--disable-frame-rate-limit"]);
  expect(frameSchedulingFlags("default")).toEqual([]);
  expect(frameSchedulingFlags(parseFrameScheduling("capture-60"))).toEqual(["--enable-features=ForceMacVSyncTimerForDebugging", "--disable-features=UseDisplayRefreshRateForTimer"]);
  expect(frameSchedulingFlags(parseFrameScheduling("no-vsync"))).toEqual(["--disable-gpu-vsync"]);
  expect(() => parseFrameScheduling("60fps")).toThrow();
  expect(() => parseRecordingOptions({ frameRate: 60.5 })).toThrow();
  expect(() => parseRecordingOptions({ maxDurationMs: 120001 })).toThrow();
  expect(() => parseRecordingOptions({ maxWidth: Infinity })).toThrow();
});

test("owned browser scheduling recognizes merged feature lists and effective final switches", () => {
  const timer = "ForceMacVSyncTimerForDebugging";
  const refresh = "UseDisplayRefreshRateForTimer";
  expect(frameSchedulingFromCommand(`/Chrome --enable-features=OtherFeature,${timer},ThirdFeature --disable-features=OtherDisabled,${refresh}`)).toBe("capture-60");
  expect(frameSchedulingFromCommand(`/Chrome --enable-features=OtherFeature --enable-features=${timer}<CaptureTrial --disable-features=${refresh}`)).toBe("capture-60");
  expect(frameSchedulingFromCommand(`/Chrome --enable-features=${timer} --enable-features=OtherFeature --disable-features=${refresh}`)).toBeUndefined();
  expect(frameSchedulingFromCommand(`/Chrome --enable-features=${timer} --disable-features=${refresh} --disable-features=OtherDisabled`)).toBeUndefined();
  expect(frameSchedulingFromCommand(`/Chrome --enable-features=${timer}Extra --disable-features=${refresh}Extra`)).toBe("default");
});

test("owned browser scheduling rejects conflicting or incomplete fixed timer policies", () => {
  const capture = "/Chrome --enable-features=ForceMacVSyncTimerForDebugging --disable-features=UseDisplayRefreshRateForTimer";
  for (const extra of ["--disable-frame-rate-limit", "--disable-gpu-vsync"]) {
    expect(frameSchedulingFromCommand(`${capture} ${extra}`)).toBeUndefined();
  }
  expect(frameSchedulingFromCommand("/Chrome --enable-features=ForceMacVSyncTimerForDebugging")).toBeUndefined();
  expect(frameSchedulingFromCommand("/Chrome --disable-features=UseDisplayRefreshRateForTimer")).toBeUndefined();
  expect(frameSchedulingFromCommand("/Chrome --enable-features=ForceMacVSyncTimerForDebugging,UseDisplayRefreshRateForTimer --disable-features=UseDisplayRefreshRateForTimer")).toBeUndefined();
  expect(frameSchedulingFromCommand("/Chrome --enable-features=ForceMacVSyncTimerForDebugging --disable-features=UseDisplayRefreshRateForTimer,ForceMacVSyncTimerForDebugging")).toBeUndefined();
  expect(frameSchedulingFromCommand("/Chrome --user-data-dir=/owned/profile")).toBe("default");
  expect(frameSchedulingFromCommand("/Chrome --disable-frame-rate-limit --disable-gpu-vsync")).toBe("uncapped");
  expect(frameSchedulingFromCommand("/Chrome --disable-gpu-vsync")).toBe("no-vsync");
});

test("capability needs both exact protocol commands", () => {
  expect(supportsScreenRecording({ domains: [{ domain: "Page", commands: [{ name: "startScreencast" }] }] })).toBe(false);
  expect(supportsScreenRecording({ domains: [{ domain: "Page", commands: [{ name: "startScreenRecording" }] }] })).toBe(false);
  expect(supportsScreenRecording({ domains: [{ domain: "Page", commands: [{ name: "startScreenRecording" }, { name: "stopScreenRecording" }] }] })).toBe(true);
});

function connection(chunks = [Buffer.from([0, 255, 128, 1]), Buffer.from("unchanged payload")]) {
  const calls: string[] = []; let closed = 0; let index = 0;
  const session: RecordingConnection = {
    async call(method, params) {
      calls.push(method);
      if (method === "Page.startScreenRecording") {
        expect(params?.audio).toBe(false); return { stream: "stream-original" };
      }
      if (method === "Page.stopScreenRecording") return { stream: "stream-flushed" };
      if (method === "IO.read") {
        expect(params?.handle).toBe("stream-flushed");
        return { data: chunks[index++].toString("base64"), base64Encoded: true, eof: index === chunks.length };
      }
      if (method === "IO.close") return {};
      throw new Error(method);
    },
    close() { closed++; },
  };
  return { session, calls, get closed() { return closed; }, bytes: Buffer.concat(chunks) };
}

test("stop flushes original binary bytes once, with private file and idempotent result", async () => {
  const directory = await mkdtemp(join(tmpdir(), "action-browser-record-"));
  const c = connection(); const recordings = new BrowserRecordings(directory);
  try {
    const started = await recordings.start(c.session, "tab-owned", {});
    expect(started.frameRateGuaranteed).toBe(false);
    const second = connection();
    await expect(recordings.start(second.session, "other-tab", {})).rejects.toThrow(/Stop the current/);
    expect(second.closed).toBe(1);
    await expect(recordings.stop("another-owner-id")).rejects.toThrow(/Unknown/);
    const result = await recordings.stop(String(started.recordingId));
    expect(result.status).toBe("finished");
    expect(await readFile(String(result.outputPath))).toEqual(c.bytes);
    expect((await stat(String(result.outputPath))).mode & 0o777).toBe(0o600);
    expect(await recordings.stop(String(started.recordingId))).toEqual(result);
    expect(c.calls.filter(method => method === "Page.stopScreenRecording")).toHaveLength(1);
    expect(c.calls.at(-1)).toBe("IO.close"); expect(c.closed).toBe(1);
  } finally { recordings.closeSync(); await rm(directory, { recursive: true, force: true }); }
});

test("byte limit fails closed, removes partial file and releases the recording owner", async () => {
  const directory = await mkdtemp(join(tmpdir(), "action-browser-record-limit-"));
  const c = connection(); const recordings = new BrowserRecordings(directory, 2);
  try {
    const started = await recordings.start(c.session, "tab", {});
    await expect(recordings.stop(String(started.recordingId))).rejects.toThrow(/byte limit/);
    expect(await readdir(directory)).toEqual([]); expect(c.closed).toBe(1);
    expect(recordings.tabId).toBeUndefined();
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("owner shutdown flushes one recording and duration expiry is bounded and retrievable", async () => {
  const directory = await mkdtemp(join(tmpdir(), "action-browser-record-owner-"));
  const recordings = new BrowserRecordings(directory); const c = connection();
  try {
    const started = await withDeadline(500, "start request", () => recordings.start(c.session, "tab", { maxDurationMs: 1000 }));
    await Bun.sleep(1200);
    const result = await recordings.stop(String(started.recordingId));
    expect(result.reason).toBe("duration-limit"); expect(c.closed).toBe(1);
    const second = await recordings.start(connection().session, "tab", {});
    await recordings.shutdown();
    expect((await recordings.stop(String(second.recordingId))).reason).toBe("owner-close");
  } finally { recordings.closeSync(); await rm(directory, { recursive: true, force: true }); }
}, 3000);

test("graceful shutdown waits for startup, while forced owner close rejects a late start", async () => {
  const directory = await mkdtemp(join(tmpdir(), "action-browser-record-start-"));
  try {
    for (const force of [false, true]) {
      const c = connection(); const recordings = new BrowserRecordings(directory);
      let release!: () => void;
      const gate = new Promise<void>(resolve => { release = resolve; });
      const session: RecordingConnection = { close: () => c.session.close(), async call(method, params) {
        if (method === "Page.startScreenRecording") await gate;
        return c.session.call(method, params);
      } };
      const started = recordings.start(session, "tab", {});
      if (force) {
        recordings.closeSync(); release();
        await expect(started).rejects.toThrow(/owner closed during startup/);
        expect(c.calls).not.toContain("Page.stopScreenRecording");
      } else {
        const shutdown = recordings.shutdown();
        expect(c.calls).not.toContain("Page.stopScreenRecording");
        release(); const result = await started; await shutdown;
        expect((await recordings.stop(String(result.recordingId))).reason).toBe("owner-close");
      }
      expect(recordings.tabId).toBeUndefined();
    }
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("a late flush response after its deadline cannot publish a recording or orphan its partial", async () => {
  const directory = await mkdtemp(join(tmpdir(), "action-browser-record-timeout-"));
  const c = connection(); const recordings = new BrowserRecordings(directory, 1024, 20);
  const session: RecordingConnection = { close: () => c.session.close(), async call(method, params) {
    // Deliberately model a transport that settles even after owner cancellation.
    if (method === "IO.read") await Bun.sleep(60);
    return c.session.call(method, params);
  } };
  try {
    const started = await recordings.start(session, "tab", {});
    await expect(recordings.stop(String(started.recordingId))).rejects.toThrow(/timed out/);
    await Bun.sleep(100);
    expect(await readdir(directory)).toEqual([]);
    expect(recordings.tabId).toBeUndefined();
    expect(c.closed).toBe(1);
  } finally { recordings.closeSync(); await rm(directory, { recursive: true, force: true }); }
});
