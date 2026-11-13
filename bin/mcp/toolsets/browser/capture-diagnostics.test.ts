import {expect, test} from "bun:test";
import {mkdtemp, readFile, stat, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {BrowserCaptureDiagnostics} from "./capture-diagnostics.ts";

function connection(data: string) {
  let complete: (value: Record<string, unknown>) => void = () => {};
  return {closed: false, calls: [] as string[],
    on(_method: string, callback: typeof complete) {complete = callback; return () => {complete = () => {};};},
    async call(method: string) {this.calls.push(method);
      if (method === "SystemInfo.getInfo") return {gpu: {devices: [{vendorString: "Test"}]}};
      if (method === "Tracing.end") complete({stream: "trace", dataLossOccurred: false});
      if (method === "IO.read") return {data, eof: true};
      return {};
    }, close() {this.closed = true;},
  };
}

test("owned trace saves exact bytes privately, GPU metadata and one idempotent stop", async () => {
  const directory = await mkdtemp(join(tmpdir(), "action-trace-"));
  try {
    const source = '{"traceEvents":[]}', c = connection(source), trace = new BrowserCaptureDiagnostics(directory);
    const started = await trace.start(c, {durationMs: 1000});
    const result = await trace.stop(String(started.traceId));
    expect(await readFile(String(result.outputPath), "utf8")).toBe(source);
    expect((await stat(String(result.outputPath))).mode & 0o777).toBe(0o600);
    expect(result.dataLossOccurred).toBe(false);
    expect(await trace.stop(String(started.traceId))).toBe(result);
    expect(c.calls.filter(call => call === "Tracing.end")).toHaveLength(1);
    expect(c.closed).toBe(true);
  } finally {await rm(directory, {recursive: true, force: true});}
});

test("trace byte bounds close the connection without publishing an oversized artifact", async () => {
  const directory = await mkdtemp(join(tmpdir(), "action-trace-"));
  try {
    const c = connection("oversized"), trace = new BrowserCaptureDiagnostics(directory, 2);
    const started = await trace.start(c, {});
    await expect(trace.stop(String(started.traceId))).rejects.toThrow("byte bound");
    expect(c.closed).toBe(true);
    await expect(readFile(join(directory, `trace-${started.traceId}.json`))).rejects.toThrow();
  } finally {await rm(directory, {recursive: true, force: true});}
});
