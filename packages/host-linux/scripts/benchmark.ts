// Read-only end-to-end burst: a test instance, never the everyday :9399 host.
// Run on each revision: bun packages/host-linux/scripts/benchmark.ts [port]
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { privateToken, privateWebSocket } from "../src/private-ipc.ts";
import { capabilities, refreshCapabilities, registerEndpoints } from "../src/endpoints.ts";
import { Router } from "../src/router.ts";
import { serve } from "../src/server.ts";

const runtime = mkdtempSync(join(tmpdir(), "lattices-benchmark-"));
const socketPath = join(runtime, "lattices.sock");
const tokenFile = join(runtime, "lattices.token");
await refreshCapabilities();
const router = new Router(() => capabilities);
registerEndpoints(router, { bindHost: "127.0.0.1", startedAt: Date.now(), clientCount: () => 1 });
const server = serve({ socketPath, tokenFile, router, log: () => {} });
const ws = privateWebSocket(socketPath, "/", { host: "localhost", "x-lattices-token": privateToken(tokenFile) });
const waiting = new Map<string, { resolve: () => void; reject: (err: Error) => void }>();
ws.onmessage = ({ data }) => {
  const reply = JSON.parse(String(data));
  const task = waiting.get(reply.id);
  if (!task) return;
  waiting.delete(reply.id);
  if (reply.error) task.reject(new Error(reply.error));
  else task.resolve();
};
let id = 0;
function call() {
  const key = String(++id);
  return new Promise<void>((resolve, reject) => {
    waiting.set(key, { resolve, reject });
    ws.send(JSON.stringify({ id: key, method: "windows.list" }));
  });
}
try {
  await new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = () => reject(new Error("WebSocket failed")); });
  for (let i = 0; i < 10; i++) await call();
  const results: Record<string, unknown>[] = [];
  for (const concurrency of [1, 2]) {
    const samples: number[] = [];
    for (let round = 0; round < 5; round++) {
      const start = performance.now();
      for (let i = 0; i < 100; i += concurrency) await Promise.all(Array.from({ length: concurrency }, call));
      samples.push(performance.now() - start);
    }
    results.push({ method: "windows.list", calls: 100, queriesPerCall: 4, concurrency, rounds: 5, samplesMs: samples.map((n) => Number(n.toFixed(2))), medianMs: Number([...samples].sort((a,b) => a-b)[2].toFixed(2)) });
  }
  console.log(JSON.stringify({ bun: Bun.version, transport: "unix", results }, null, 2));
} finally {
  ws.close();
  server.stop();
  rmSync(runtime, { recursive: true, force: true });
}
