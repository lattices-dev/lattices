import { test, expect } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

test("hosts add preserves config and never probes a host", () => {
  const home = mkdtempSync(join(tmpdir(), "machines-cli-"));
  try {
    mkdirSync(join(home, ".lattices"));
    const file = join(home, ".lattices/hosts.json");
    writeFileSync(file, JSON.stringify({ version: 7, hosts: { existing: { address: "offline.invalid" } } }));
    const run = (...args: string[]) => Bun.spawnSync([process.execPath, resolve("bin/lattices.ts"), "hosts", "add", ...args], {
      env: { ...process.env, HOME: home, LATTICES_HOSTS: "" }, timeout: 5000,
    });
    const result = run("fixture", "unreachable.invalid", "9500");
    expect(result.exitCode).toBe(0);
    expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({ version: 7, hosts: {
      existing: { address: "offline.invalid" }, fixture: { address: "unreachable.invalid", port: 9500 },
    } });
    expect(run("bad", "offline.invalid", "99999").exitCode).not.toBe(0);
    writeFileSync(file, "broken");
    expect(run("fixture").exitCode).not.toBe(0);
    expect(readFileSync(file, "utf8")).toBe("broken");
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("Machines CLI routes mutations to an isolated mock daemon", async () => {
  const requests: { method: string; params: unknown }[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
      if (server.upgrade(request)) return;
      return new Response("WebSocket required", { status: 400 });
    },
    websocket: {
      message(ws, data) {
        const request = JSON.parse(String(data));
        requests.push(request);
        ws.send(JSON.stringify({ id: request.id, result: { ok: true, kept: true, sharing: true } }));
      },
    },
  });
  try {
    for (const [args, method, params] of [
      [["visit", "place", "fixture", "2560", "-300"], "visit.place", { name: "fixture", x: 2560, y: -300 }],
      [["visit", "host", "on"], "visit.host", { on: true }],
      [["visit", "side", "fixture", "left"], "visit.side", { host: "fixture", side: "left" }],
      [["visit", "forget", "fixture"], "visit.forget", { host: "fixture" }],
      [["mouse", "home"], "mouse.home", null],
      [["mouse", "find"], "mouse.find", null],
    ] as const) {
      requests.length = 0;
      const proc = Bun.spawn([process.execPath, resolve("bin/lattices.ts"), ...args], {
        env: { ...process.env, LATTICES_DAEMON_HOST: "127.0.0.1", LATTICES_DAEMON_PORT: String(server.port) },
        stdout: "pipe", stderr: "pipe",
      });
      expect(await proc.exited).toBe(0);
      expect(requests.map(r => r.method)).toEqual(["daemon.status", method]);
      expect(requests[1].params).toEqual(params);
    }
    requests.length = 0;
    for (const verb of ["share", "keep", "stop", "status"]) {
      const removed = Bun.spawn([process.execPath, resolve("bin/lattices.ts"), "mouse", verb], {
        env: { ...process.env, LATTICES_DAEMON_HOST: "127.0.0.1", LATTICES_DAEMON_PORT: String(server.port) },
        stdout: "pipe", stderr: "pipe",
      });
      expect(await removed.exited).not.toBe(0);
      expect(requests).toEqual([]);
    }
    const invalid = Bun.spawn([process.execPath, resolve("bin/lattices.ts"), "visit", "side", "fixture", "diagonal"], {
      env: { ...process.env, LATTICES_DAEMON_HOST: "127.0.0.1", LATTICES_DAEMON_PORT: String(server.port) },
      stdout: "pipe", stderr: "pipe",
    });
    await invalid.exited;
    expect(requests.map(r => r.method)).toEqual(["daemon.status"]);
    expect(await new Response(invalid.stdout).text()).toContain("Usage:");
  } finally { server.stop(true); }
}, 20000);
