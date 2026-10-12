import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { machineStatuses, mergeMachines } from "../bin/cli/machines.ts";

test("machine inventory merges transitively and preserves daemon ports and offline rows", async () => {
  const hosts = [{name: "local", address: "127.0.0.1", port: 9399, source: "local" as const},
    {name: "alias", address: "100.64.0.1", port: 9500, source: "config" as const},
    {name: "offline", address: "offline.invalid", port: 9399, source: "config" as const}];
  const paired = [{name: "ARCHIE", address: "100.64.0.1:5287", side: "left"}, {name: "alias", address: "other:5287"}];
  expect(mergeMachines(hosts, paired, "mini")).toHaveLength(3);
  const rows = await machineStatuses(hosts, paired, "mini", async (host) => {
    if (host.name === "offline") throw new Error("offline fixture");
    if (host.name === "alias") expect(host.port).toBe(9500);
    return {platform: "linux", build: {version: "0.13.3", commit: "abcdef"}, displays: [{}, {}]};
  });
  expect(rows.find(r => r.local)?.name).toBe("mini");
  expect(rows.find(r => r.paired)?.displays).toBe(2);
  expect(rows.find(r => r.name === "offline")?.reachable).toBe(false);
});

test("cluster CLI targets only the selected mock host and rejects local-only commands", async () => {
  const requests: {method: string; params: any}[] = [];
  const server = Bun.serve({hostname: "127.0.0.1", port: 0,
    fetch(req, server) { if (server.upgrade(req)) return; return new Response("ws", {status: 400}); },
    websocket: {message(ws, data) {
      const req = JSON.parse(String(data)); requests.push(req);
      const result = req.method === "displays.list" ? {displays: [{index: 1, name: "DELL", width: 100, height: 100, windows: 0}]} : {ok: true};
      ws.send(JSON.stringify({id: req.id, result}));
    }}
  });
  const home = mkdtempSync(join(tmpdir(), "cluster-cli-"));
  mkdirSync(join(home, ".lattices"));
  writeFileSync(join(home, ".lattices/hosts.json"), JSON.stringify({hosts: {fixture: {address: "127.0.0.1", port: server.port}}}));
  const run = async (args: string[]) => {
    const child = Bun.spawn([process.execPath, resolve("bin/lattices.ts"), ...args], {
      env: {...process.env, HOME: home, LATTICES_HOSTS: "", LATTICES_DAEMON_HOST: "127.0.0.1", LATTICES_DAEMON_PORT: args[0] === "@local" ? String(server.port) : "1"}, stdout: "pipe", stderr: "pipe"});
    const [code, out, err] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    return {code, out, err};
  };
  try {
    for (const [args, method, params] of [
      [["bring", "dell"], "bring", {display: "dell"}],
      [["bring", "--undo"], "bring", {undo: true}],
      [["main", "U32", "--keep"], "main", {display: "U32", keep: true}],
      [["elsewhere", "u32", "archie"], "elsewhere", {display: "u32", name: "archie"}],
      [["here", "2"], "here", {display: "2"}],
      [["visit", "archie"], "visit.start", {host: "archie"}],
      [["home"], "home", {}],
      [["display", "list"], "displays.list", {}],
      [["visit", "main", "dell"], "visit.main", {screen: "dell"}],
    ] as const) {
      requests.length = 0;
      const result = await run(["@fixture", ...args]);
      expect(result.code, result.err).toBe(0);
      expect(requests.map(r => r.method)).toEqual(["daemon.status", method]);
      expect(requests[1].params).toEqual(params);
    }
    for (const command of ["start", "app", "hosts", "update", "hud"]) {
      requests.length = 0;
      const result = await run(["@fixture", command]);
      expect(result.code).not.toBe(0); expect(result.err).toContain("local-only"); expect(requests).toEqual([]);
    }
    requests.length = 0;
    const named = await run(["@fixture", "window", "move", "123", "--display", "dell", "--dry-run", "--json"]);
    expect(named.code, named.err).toBe(0);
    expect(requests.map(r => r.method)).toEqual(["daemon.status", "displays.list", "daemon.status", "windows.move"]);
    expect(requests[3].params.display).toBe(1);
    expect(requests[3].params.dryRun).toBe(true);
    expect((await run(["@local", "home"])).code).toBe(0);
  } finally { server.stop(true); rmSync(home, {recursive: true, force: true}); }
}, 30000);

test("remote policy permits daemon wrappers and blocks local execution aliases", async () => {
  const {supportsRemote} = await import("../bin/cli/remote.ts");
  for (const command of ["app", "update", "start", "init", "hosts", "machines", "hud"]) expect(supportsRemote([command])).toBe(false);
  for (const sub of ["log", "audit", "record-command", "recordCommand", "record-run", "recordRun", "record-exec", "recordExec"]) expect(supportsRemote(["capture", sub])).toBe(false);
  for (const command of ["windows", "map", "run", "call", "sessions", "display", "bring"]) expect(supportsRemote([command])).toBe(true);
  for (const sub of ["show", "hide", "toggle", "status", "hud"]) expect(supportsRemote(["actor", sub])).toBe(true);
  expect(supportsRemote(["actor", "app"])).toBe(false);
});

test("older responding daemons stay reachable with unknown build identity", async () => {
  const rows = await machineStatuses([{name: "old", address: "old.invalid", port: 9399, source: "config"}], [], "local", async () => { throw new Error("Unknown method: host.describe"); });
  expect(rows[0].reachable).toBe(true); expect(rows[0].version).toBeNull();
});

test("configured machine placement survives without a visit pairing", async () => {
  const placement = {x: 100, y: -20, width: 100, height: 100};
  const rows = await machineStatuses([{name: "air", address: "air.invalid", port: 9399, source: "config"}], [], "local",
    async () => ({platform: "macos", displays: []}), {air: placement});
  expect(rows[0].paired).toBe(false); expect(rows[0].placement).toEqual(placement);
});

test("saved unplaced pairing does not report its legacy side", async () => {
  const rows = await machineStatuses([], [{name: "air", address: "air.invalid", side: "left", unplaced: true}], "local",
    async () => ({platform: "macos", displays: []}));
  expect(rows[0].paired).toBe(true); expect(rows[0].placement).toBeNull();
});

test("a pairing through an ssh tunnel stays its own machine, not this one", () => {
  const hosts = [{name: "local", address: "127.0.0.1", port: 9399, source: "local" as const},
    {name: "archie", address: "archie", port: 9399, source: "config" as const}];
  const merged = mergeMachines(hosts, [{name: "archie", address: "127.0.0.1:5288"}], "mini");
  expect(merged).toHaveLength(2);
  expect(merged.find(m => m.pair)?.host.name).toBe("archie");
});
