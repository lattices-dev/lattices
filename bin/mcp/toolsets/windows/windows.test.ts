import { afterAll, beforeAll, expect, test } from "bun:test";
import { loadToolsets } from "../../registry.ts";
import { callWindowTool } from "./index.ts";

// A fake local daemon: the toolset reaches "local" through LATTICES_DAEMON_HOST/PORT.
const calls: { method: string; params: Record<string, unknown> }[] = [];
let server: ReturnType<typeof Bun.serve>;
const savedEnv = { host: process.env.LATTICES_DAEMON_HOST, port: process.env.LATTICES_DAEMON_PORT };

beforeAll(() => {
  server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch: (req, srv) => (srv.upgrade(req, { data: undefined }) ? undefined : new Response("no")),
    websocket: {
      message(ws, raw) {
        const { id, method, params } = JSON.parse(String(raw));
        calls.push({ method, params });
        const results: Record<string, unknown> = {
          "search.query": [
            { wid: 42, app: "iTerm2", title: "zsh", score: 5, matchSources: ["cwd"], terminalTabs: [{ tabIndex: 0, cwd: "~/dev/vox", tabTitle: "zsh", hasClaude: true, tmuxSession: "" }] },
          ],
          "windows.focus": { ok: true, wid: 42 },
          "windows.place": { receiptId: "exec-1", status: "executed" },
          "layers.list": { layers: [{ id: "main", label: "Main", index: 0, slot: 1 }], active: 0 },
          "layers.activate": { ok: true },
          "history.undo": { receiptId: "exec-2", undoOf: ["exec-1"] },
        };
        ws.send(JSON.stringify(method in results ? { id, result: results[method], error: null } : { id, result: null, error: `Unknown method: ${method}` }));
      },
    },
  });
  process.env.LATTICES_DAEMON_HOST = "127.0.0.1";
  process.env.LATTICES_DAEMON_PORT = String(server.port);
});

afterAll(() => {
  server.stop(true);
  for (const [key, value] of [["LATTICES_DAEMON_HOST", savedEnv.host], ["LATTICES_DAEMON_PORT", savedEnv.port]] as const) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

const last = (method: string) => [...calls].reverse().find((c) => c.method === method)?.params;

test("the registry serves the windows toolset", async () => {
  const [windows] = await loadToolsets(["windows"]);
  expect(windows!.tools.map((t) => t.name)).toEqual([
    "windows_search", "windows_place", "windows_focus", "layers_list", "layers_switch", "history_undo",
  ]);
});

test("windows_search is basic by default and searches every source when deep", async () => {
  const basic = await callWindowTool("windows_search", { query: "vox" });
  expect(last("search.query")).toEqual({ query: "vox" });
  expect(basic.structuredContent).toEqual({
    results: [{ wid: 42, app: "iTerm2", title: "zsh", score: 5, reasons: ["cwd"], tabs: [{ tab: 0, cwd: "~/dev/vox", title: "zsh", hasClaude: true, tmuxSession: "" }] }],
  });

  await callWindowTool("windows_search", { query: "vox", deep: true });
  expect(last("search.query")).toEqual({ query: "vox", sources: ["all"] });

  await callWindowTool("windows_search", { query: "vox", deep: true, sources: ["ocr"] });
  expect(last("search.query")).toEqual({ query: "vox", sources: ["ocr"] });
});

test("windows_place by wid normalizes the slot and surfaces the receipt id", async () => {
  const placed = await callWindowTool("windows_place", { wid: 42, placement: "left_half" });
  expect(last("windows.place")).toEqual({ wid: 42, placement: "left" });
  expect(placed.structuredContent).toMatchObject({ receiptId: "exec-1" });

  await callWindowTool("windows_place", { wid: 42 });
  expect(last("windows.place")).toEqual({ wid: 42, placement: "bottom-right" });

  await expect(callWindowTool("windows_place", { wid: 42, placement: "sideways" })).rejects.toThrow("Unknown placement");
});

test("windows_place by query deep-searches, focuses and places the top match like lats place", async () => {
  calls.length = 0;
  const placed = await callWindowTool("windows_place", { query: "vox", placement: "right" });
  expect(calls.map((c) => c.method)).toEqual(["search.query", "windows.focus", "windows.place"]);
  expect(last("search.query")).toEqual({ query: "vox", sources: ["all"] });
  expect(last("windows.place")).toEqual({ wid: 42, placement: "right", dryRun: false });
  expect(placed.structuredContent).toMatchObject({ receiptId: "exec-1", window: { wid: 42 } });
});

test("windows_focus, layers and history_undo pass through to their daemon methods", async () => {
  await callWindowTool("windows_focus", { session: "vox" });
  expect(last("windows.focus")).toEqual({ session: "vox" });

  const layers = await callWindowTool("layers_list", {});
  expect(layers.structuredContent).toMatchObject({ active: 0 });

  await callWindowTool("layers_switch", { layer: "1" });
  expect(last("layers.activate")).toEqual({ index: 0 });
  await callWindowTool("layers_switch", { layer: "Main", mode: "tile" });
  expect(last("layers.activate")).toEqual({ name: "Main", mode: "tile" });
  await expect(callWindowTool("layers_switch", { layer: "5" })).rejects.toThrow("pad's centre");

  const undone = await callWindowTool("history_undo", { receiptId: "exec-1" });
  expect(last("history.undo")).toEqual({ receiptId: "exec-1", source: "mcp" });
  expect(undone.structuredContent).toMatchObject({ receiptId: "exec-2", undoOf: ["exec-1"] });
});

test("errors surface as tool errors through the toolset", async () => {
  const { windowsToolset } = await import("./index.ts");
  const result = await windowsToolset.callTool("windows_focus", {});
  expect(result.isError).toBe(true);
  expect(result.content[0]).toMatchObject({ text: "windows_focus needs a wid or a session" });
});
