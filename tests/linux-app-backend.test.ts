import { expect, test } from "bun:test";
import { fileURLToPath } from "node:url";
import { mkdtempSync, mkdirSync, writeFileSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

test("app bridge correlates receipts, reports failed health, and blocks unsupported actions", async () => {
  const calls: string[] = [];
  const windows = [{ wid: 11, app: "kitty", title: "Test editor", pid: -1, spaceIds: [1] }];
  const describe = {
    platform: "linux", hostname: "bridge-fixture", displays: [],
    methods: ["desktop.snapshot", "windows.list", "windows.search", "spaces.list", "tmux.list", "layers.list"],
    capabilities: ["windows.read", "spaces.read", "sessions.tmux"],
    capabilityHealth: { "windows.place": { available: false, reason: "Placement unavailable in fixture" } },
    eventStream: { state: "connected" },
  };
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) { return server.upgrade(request) ? undefined : new Response("Upgrade required", { status: 426 }); },
    websocket: {
      message(socket, data) {
        const request = JSON.parse(String(data));
        calls.push(request.method);
        if (request.method === "windows.search") { socket.send(JSON.stringify({ id: request.id, error: "Fixture search unavailable" })); return; }
        const result = ({
          "host.describe": describe,
          "desktop.snapshot": { windows, displays: [], sessions: [] },
          "daemon.status": { platform: "linux", version: "test" },
          "events.subscribe": { subscribed: true },
          "windows.list": windows,
          "spaces.list": [], "tmux.list": [], "layers.list": { layers: [], active: -1 },
        } as Record<string, unknown>)[request.method];
        socket.send(JSON.stringify({ id: request.id, result }));
      },
    },
  });
  const fixture = mkdtempSync(join(tmpdir(), "lattices-bridge-appearance-"));
  const current = join(fixture, "state/omarchy/current");
  mkdirSync(current, { recursive: true });
  const child = Bun.spawn([process.execPath, fileURLToPath(new URL("../apps/linux/backend.ts", import.meta.url))], {
    stdin: "pipe", stdout: "pipe", stderr: "pipe",
    env: { ...process.env, LATTICES_LINUX_PORT: String(server.port), XDG_CONFIG_HOME: join(fixture, "config"), XDG_STATE_HOME: join(fixture, "state") },
  });
  const messages: Record<string, any>[] = [];
  const listeners = new Set<() => void>();
  const pump = (async () => {
    const reader = child.stdout.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      buffer += decoder.decode(value, { stream: true });
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        messages.push(JSON.parse(buffer.slice(0, newline)));
        buffer = buffer.slice(newline + 1);
        for (const listener of listeners) listener();
      }
    }
  })();
  const waitFor = (predicate: (message: Record<string, any>) => boolean) => new Promise<Record<string, any>>((resolve, reject) => {
    const timeout = setTimeout(() => { listeners.delete(check); reject(new Error("App bridge response timed out")); }, 5000);
    function check() {
      const message = messages.find(predicate);
      if (message) { clearTimeout(timeout); listeners.delete(check); resolve(message); }
    }
    listeners.add(check); check();
  });
  const send = (method: string, requestId: string, params = {}) => {
    child.stdin.write(JSON.stringify({ method, requestId, params }) + "\n");
    child.stdin.flush();
    return waitFor(message => message.requestId === requestId);
  };
  try {
    await waitFor(message => message.type === "state");
    const initialAppearance = await waitFor(message => message.type === "appearance");
    expect(initialAppearance.appearance.source).toBe("default");
    const list = await send("windows.list", "inventory-1");
    expect(list.type).toBe("done");
    expect(list.result).toEqual(windows);
    const failure = await send("windows.search", "search-2", { query: "test" });
    expect(failure).toMatchObject({ type: "error", requestId: "search-2", message: "Fixture search unavailable" });
    const doctor = await send("app.doctor", "doctor-3");
    expect(doctor.type).toBe("done");
    expect(doctor.result.report.ok).toBe(false);
    expect(doctor.result.report.checks).toContainEqual({ name: "Window placement", state: "fail", detail: "Placement unavailable in fixture" });
    const blocked = await send("shell.exec", "blocked-4", { command: "touch /tmp/not-authorized" });
    expect(blocked).toMatchObject({ type: "error", requestId: "blocked-4", message: "Unsupported app action" });
    expect(calls).not.toContain("shell.exec");
    expect(calls.every(method => ["host.describe", "desktop.snapshot", "daemon.status", "events.subscribe", "windows.list", "windows.search"].includes(method))).toBe(true);
    server.stop(true);
    await waitFor(message => message.type === "offline");
    mkdirSync(join(current, "theme"));
    writeFileSync(join(current, "theme/colors.toml"), 'mode = "light"\nbackground = "#fafafa"\nforeground = "#222222"\naccent = "#7654aa"\n');
    writeFileSync(join(current, "theme.name"), "fixture-light\n");
    const light = await waitFor(message => message.type === "appearance" && message.appearance.theme === "fixture-light");
    expect(light.appearance.mode).toBe("light");
    expect(child.exitCode).toBeNull();
    mkdirSync(join(current, "next"));
    writeFileSync(join(current, "next/colors.toml"), 'mode = "dark"\nbackground = "#141414"\nforeground = "#eeeeee"\naccent = "#e68e0d"\n');
    renameSync(join(current, "theme"), join(current, "previous"));
    renameSync(join(current, "next"), join(current, "theme"));
    writeFileSync(join(current, "theme.name"), "fixture-dark\n");
    const dark = await waitFor(message => message.type === "appearance" && message.appearance.theme === "fixture-dark");
    expect(dark.appearance.mode).toBe("dark");
    expect(dark.appearance.tokens.accent).toBe("#e68e0d");
  } finally {
    child.kill();
    await child.exited;
    server.stop(true);
    await pump;
    rmSync(fixture, { recursive: true, force: true });
  }
}, 10000);
