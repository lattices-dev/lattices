import { randomUUID } from "node:crypto";
import { mkdir, open, rename, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { boundedWait, checkDeadline, outsideRequestDeadline, withDeadline } from "./transport.ts";

type Json = Record<string, unknown>;
type Connection = {call(method: string, params?: Json): Promise<Json>; on(method: string, callback: (params: Json) => void): () => void; close(): void};
type Active = {id: string; session: Connection; startedAt: string; complete: Promise<Json>; unsubscribe: () => void; timer?: ReturnType<typeof setTimeout>; starting?: Promise<void>; stopping?: Promise<Json>; gpu: Json};
const categories = ["devtools.timeline", "cc", "viz", "gpu", "benchmark", "disabled-by-default-devtools.timeline.frame", "disabled-by-default-devtools.timeline.layers"];

/** Opt-in browser-process tracing. No screenshots, DOM changes, or capture-frame synthesis. */
export class BrowserCaptureDiagnostics {
  private active?: Active;
  private last?: {id: string; result?: Json; error?: Error};
  constructor(private artifactRoot: string, private maximumBytes = 100 * 1024 * 1024) {}

  async start(session: Connection, args: Json): Promise<Json> {
    const durationMs = args.durationMs ?? 40000;
    if (this.active || typeof durationMs !== "number" || !Number.isInteger(durationMs) || durationMs < 1000 || durationMs > 60000) {
      session.close(); throw new Error(this.active ? "Stop this owner's active trace first." : "durationMs must be an integer from 1000 to 60000.");
    }
    let resolveComplete!: (value: Json) => void;
    const complete = new Promise<Json>(resolve => { resolveComplete = resolve; });
    const state: Active = {id: randomUUID(), session, startedAt: new Date().toISOString(), complete,
      unsubscribe: session.on("Tracing.tracingComplete", resolveComplete), gpu: {}};
    this.active = state;
    try {
      state.starting = (async () => {
        state.gpu = await session.call("SystemInfo.getInfo");
        await session.call("Tracing.start", {transferMode: "ReturnAsStream", streamFormat: "json", traceConfig: {
          recordMode: "recordUntilFull", traceBufferSizeInKb: 51200, includedCategories: categories,
        }});
        if (this.active !== state) throw new Error("Trace owner closed during startup.");
        state.timer = outsideRequestDeadline(() => setTimeout(() => { void this.stop(state.id).catch(() => {}); }, durationMs)); state.timer.unref();
      })();
      await state.starting;
      return {traceId: state.id, status: "tracing", startedAt: state.startedAt, durationMs, categories,
        gpu: state.gpu.gpu, maximumBytes: this.maximumBytes, warning: "Tracing adds measurement overhead; compare source timestamps separately."};
    } catch (error) { state.unsubscribe(); session.close(); if (this.active === state) this.active = undefined; throw error; }
  }

  async stop(id: string): Promise<Json> {
    const state = this.active;
    if (!state || state.id !== id) {
      if (this.last?.id === id) { if (this.last.error) throw this.last.error; return this.last.result!; }
      throw new Error("Unknown traceId for this MCP owner.");
    }
    await state.starting;
    if (this.active !== state) throw new Error("Trace owner closed during startup.");
    if (state.stopping) return state.stopping;
    clearTimeout(state.timer);
    state.stopping = outsideRequestDeadline(() => withDeadline(30000, "Finish browser trace", async () => {
      let handle: string | undefined;
      let file: Awaited<ReturnType<typeof open>> | undefined;
      const outputPath = join(this.artifactRoot, `trace-${id}.json`), partial = `${outputPath}.partial`;
      try {
        await state.session.call("Tracing.end");
        const completion = await boundedWait(state.complete, "Wait for browser trace stream", () => state.session.close());
        if (typeof completion.stream !== "string") throw new Error("Chrome did not return a trace stream.");
        handle = completion.stream;
        await mkdir(this.artifactRoot, {recursive: true, mode: 0o700}); checkDeadline();
        file = await open(partial, "wx", 0o600); checkDeadline();
        let bytes = 0;
        for (;;) {
          const chunk = await state.session.call("IO.read", {handle, size: 65536});
          if (typeof chunk.data !== "string") throw new Error("Invalid trace stream data.");
          const data = Buffer.from(chunk.data, chunk.base64Encoded ? "base64" : "utf8");
          bytes += data.length;
          if (bytes > this.maximumBytes) throw new Error("Browser trace exceeded its byte bound.");
          await file.write(data); checkDeadline();
          if (chunk.eof) break;
        }
        await file.sync(); checkDeadline(); await file.close(); file = undefined; checkDeadline();
        await rename(partial, outputPath);
        const metadataPath = join(this.artifactRoot, `trace-${id}-metadata.json`);
        const result = {traceId: id, status: "finished", outputPath, metadataPath, startedAt: state.startedAt,
          finishedAt: new Date().toISOString(), bytes, dataLossOccurred: completion.dataLossOccurred === true, gpu: state.gpu, categories};
        await writeFile(metadataPath, JSON.stringify(result), {flag: "wx", mode: 0o600});
        this.last = {id, result}; return result;
      } finally {
        if (handle) await state.session.call("IO.close", {handle}).catch(() => {});
        await file?.close().catch(() => {}); await unlink(partial).catch(() => {});
        state.unsubscribe(); state.session.close(); if (this.active === state) this.active = undefined;
      }
    })).catch(error => { this.last = {id, error: error instanceof Error ? error : new Error(String(error))}; state.session.close(); if (this.active === state) this.active = undefined; throw error; });
    return state.stopping;
  }

  async shutdown(): Promise<void> { if (this.active) await this.stop(this.active.id).catch(() => {}); }
  closeSync(): void { const state = this.active; if (!state) return; clearTimeout(state.timer); state.unsubscribe(); state.session.close(); this.active = undefined; }
}
