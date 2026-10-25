import { describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { createServer } from "node:net";
import type { ChildProcess } from "node:child_process";
import { LiveVNC, probeVNC, wayvncArguments } from "../src/live.ts";

class FakeProcess extends EventEmitter {
  exitCode: number | null = null;
  signalCode: string | null = null;
  stderr = new EventEmitter();
  killed = false;
  kill() { this.killed = true; this.signalCode = "SIGTERM"; this.emit("exit"); return true; }
}

function fixture(probes: ("closed" | "vnc" | "occupied")[], onSpawn?: (child: FakeProcess) => void) {
  const child = new FakeProcess();
  const calls: string[][] = [];
  const manager = new LiveVNC({
    spawn: (args) => { calls.push(args); queueMicrotask(() => onSpawn?.(child)); return child as unknown as ChildProcess; },
    probe: async () => probes.shift() ?? "closed", delay: async () => {}, attempts: 3,
  });
  return { manager, child, calls };
}

describe("VNC server lifecycle", () => {
  test("uses a single loopback address:port and rejects invalid ports/public binds", () => {
    expect(wayvncArguments({ host: "127.0.0.1", port: 5901, output: "DP-1" })).toEqual(["-o", "DP-1", "127.0.0.1:5901"]);
    expect(wayvncArguments({ host: "::1", port: 5900 })).toEqual(["[::1]:5900"]);
    expect(wayvncArguments({ host: "127.0.0.1", port: 5901 }, false)).toEqual(["127.0.0.1", "5901"]);
    for (const port of [0, -1, 65536, 1.5, NaN]) expect(() => wayvncArguments({ host: "127.0.0.1", port })).toThrow();
    expect(() => wayvncArguments({ host: "0.0.0.0", port: 5900 })).toThrow("loopback");
  });

  test("concurrent starts share one child and never silently change the output", async () => {
    const { manager, child, calls } = fixture(["closed", "vnc"]);
    const first = manager.start("127.0.0.1", 5900, "DP-1");
    const second = manager.start("127.0.0.1", 5900, "DP-1");
    expect(first).toBe(second);
    await expect(manager.start("127.0.0.1", 5901)).rejects.toThrow("starting");
    expect((await first).running).toBe(true);
    expect(calls).toHaveLength(1);
    expect((await manager.start("127.0.0.1", 5900)).running).toBe(true);
    await expect(manager.start("127.0.0.1", 5900, "DP-2")).rejects.toThrow("already running");
    manager.stop();
    expect(child.killed).toBe(true);
    expect(manager.status().running).toBe(false);
  });

  test("only adopts real external VNC and never kills it", async () => {
    const { manager, child, calls } = fixture(["vnc"]);
    expect(await manager.start("127.0.0.1", 5900)).toMatchObject({ running: true, external: true });
    manager.stop();
    expect(child.killed).toBe(false);
    expect(calls).toHaveLength(0);
    const occupied = fixture(["occupied"]);
    await expect(occupied.manager.start("127.0.0.1")).rejects.toThrow("not answering as VNC");
    expect(occupied.calls).toHaveLength(0);
  });

  test("spawn errors and timeout clear owned children", async () => {
    const missing = fixture(["closed"], child => child.emit("error", new Error("ENOENT")));
    await expect(missing.manager.start("127.0.0.1")).rejects.toThrow("ENOENT");
    expect(missing.manager.status().running).toBe(false);
    expect(missing.child.killed).toBe(true);
    const timeout = fixture(["closed"]);
    await expect(timeout.manager.start("127.0.0.1")).rejects.toThrow("did not answer");
    expect(timeout.child.killed).toBe(true);
    expect(timeout.manager.status().running).toBe(false);
  });

  test("stop during preflight prevents a late server spawn", async () => {
    const { manager, calls } = fixture(["closed", "vnc"]);
    const startup = manager.start("127.0.0.1");
    manager.stop();
    await expect(startup).rejects.toThrow("cancelled");
    expect(calls).toHaveLength(0);
  });

  test("signal exit clears running state", async () => {
    const { manager, child } = fixture(["closed", "vnc"]);
    await manager.start("127.0.0.1");
    child.kill();
    expect(manager.status().running).toBe(false);
  });
});

test("RFB probe distinguishes a fragmented banner from an unrelated listener", async () => {
  let vnc = true;
  const server = createServer(socket => {
    socket.on("error", () => {});
    socket.write(vnc ? "RFB 003." : "HTTP/1.1 200 OK\r\n");
    if (vnc) setTimeout(() => socket.end("008\n"), 5);
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("missing test port");
  try {
    expect(await probeVNC("127.0.0.1", address.port)).toBe("vnc");
    vnc = false;
    expect(await probeVNC("127.0.0.1", address.port)).toBe("occupied");
  } finally { await new Promise<void>(resolve => server.close(() => resolve())); }
  expect(await probeVNC("127.0.0.1", address.port)).toBe("closed");
});
