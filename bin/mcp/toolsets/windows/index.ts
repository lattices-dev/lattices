// The `windows` toolset: this Mac's window controls as first-class tools --
// search, place, focus, layers, undo and saved remote apps -- so an agent uses the same verbs as
// `lats search`, `lats place` and `lats layer` instead of host_call on "local".
// Every tool wraps an existing daemon method; the CLI's search and place logic
// is reused, not copied.

import { callHost, resolveHost } from "../../../hosts.ts";
import { layerTarget } from "../../../cli/layer.ts";
import { placeWithClient, searchWithClient, type DaemonCaller } from "../../../cli/search.ts";
import { normalizePlacement } from "../../../cli/window.ts";
import { toolError, type JsonObject, type ToolDefinition, type ToolResult, type Toolset } from "../../types.ts";

const object = (properties: JsonObject, required: string[] = []): JsonObject => ({
  type: "object",
  properties,
  required,
  additionalProperties: false,
});

const readOnly = { readOnlyHint: true, openWorldHint: false };
const mutating = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };

const placementProp = {
  description:
    "Slot: left, right, top-left, bottom-right, center, maximize, left-third, grid:3x2:0,1 ... or {kind:'fractions',x,y,w,h}. Default bottom-right.",
};

export const WINDOW_TOOLS: readonly ToolDefinition[] = [
  {
    name: "windows_search",
    title: "Search windows",
    description:
      "Find windows on this Mac by title, app, session, terminal cwd/tabs (search.query). Use the basic search first; set deep: true only when it misses, e.g. a project that appears only in a terminal's cwd. Returns wid, app, title, score and match reasons.",
    inputSchema: object(
      {
        query: { type: "string", description: "Search text" },
        deep: { type: "boolean", description: "Search every source, including OCR and processes (like lats search --deep)" },
        sources: {
          type: "array",
          items: { type: "string" },
          description: "Explicit sources: titles, apps, sessions, cwd, tabs, tmux, ocr, processes, all. Overrides deep.",
        },
      },
      ["query"]
    ),
    annotations: readOnly,
  },
  {
    name: "windows_place",
    title: "Place a window",
    description:
      "Move and resize a window (windows.place). Give wid, or query to deep-search, focus and place the top match like lats place. Returns the receipt; its receiptId undoes it with history_undo.",
    inputSchema: object({
      wid: { type: "number", description: "Window id from windows_search" },
      query: { type: "string", description: "Find the window by search instead of wid" },
      placement: placementProp,
      display: { type: "number", description: "Target display index (wid only)" },
      dryRun: { type: "boolean", description: "Plan the move without moving anything" },
    }),
    annotations: mutating,
  },
  {
    name: "windows_focus",
    title: "Focus a window",
    description: "Bring a window to the front by wid or tmux session name (windows.focus).",
    inputSchema: object({
      wid: { type: "number", description: "Window id (takes priority)" },
      session: { type: "string", description: "Tmux session name" },
    }),
    annotations: mutating,
  },
  {
    name: "layers_list",
    title: "List workspace layers",
    description: "Workspace layers with index, ⌘⌥ pad slot and label, plus the active index (layers.list).",
    inputSchema: object({}),
    annotations: readOnly,
  },
  {
    name: "layers_switch",
    title: "Switch workspace layer",
    description:
      "Switch layer as ⌘⌥ does (layers.activate). layer is a name or pad slot digit (1-4, 6-9); or pass index from layers_list. mode: focus (default), tile, launch.",
    inputSchema: object({
      layer: { type: "string", description: "Layer id/label, or its ⌘⌥ pad slot digit" },
      index: { type: "number", description: "Layer index from layers_list" },
      mode: { type: "string", enum: ["focus", "tile", "launch"] },
    }),
    annotations: mutating,
  },
  {
    name: "history_undo",
    title: "Undo a window action",
    description:
      "Restore windows from an action receipt (history.undo): pass receiptId from windows_place, or nothing to undo the latest undoable placement.",
    inputSchema: object({
      receiptId: { type: "string", description: "Receipt to undo" },
      requestId: { type: "string", description: "Request group to undo" },
      wid: { type: "number", description: "Limit the undo to one window" },
      steps: { type: "number", description: "Recent undoable groups to restore (default 1)" },
      dryRun: { type: "boolean", description: "Plan the restore without moving windows" },
    }),
    annotations: mutating,
  },
  {
    name: "views_list",
    title: "List saved remote apps",
    description: "Remote apps saved to open as their own window here (views.list): id, host, app, name, and the Mac window id of any that are open.",
    inputSchema: object({}),
    annotations: readOnly,
  },
  {
    name: "views_save",
    title: "Save a remote app",
    description:
      "Save an app on a host so views_open can open it as its own window here (views.save). Also makes it a Mac app for the Dock, ⌘Tab and Spotlight; app_path is where. id defaults to app-host, e.g. spotify-archie; name is the window's name here.",
    inputSchema: object({
      host: { type: "string", description: "Configured host name, e.g. archie" },
      app: { type: "string", description: "App name on the host, e.g. Spotify" },
      name: { type: "string", description: "Window name here; defaults to the app" },
      id: { type: "string", description: "Letters, digits, - and _" },
      width: { type: "number", description: "First window width in points (with height)" },
      height: { type: "number", description: "First window height in points (with width)" },
    }, ["host", "app"]),
    annotations: mutating,
  },
  {
    name: "views_open",
    title: "Open a saved remote app",
    description: "Open a saved remote app as its own window here, or bring it forward (views.open). Returns window, its id for windows_focus and windows_place.",
    inputSchema: object({ id: { type: "string", description: "Id from views_list" } }, ["id"]),
    annotations: mutating,
  },
  {
    name: "views_remove",
    title: "Forget a saved remote app",
    description: "Delete a saved remote app and its Mac app (views.remove). An open one is closed and its app returned to its host.",
    inputSchema: object({ id: { type: "string", description: "Id from views_list" } }, ["id"]),
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  },
];

const text = (value: unknown): ToolResult => {
  const structured = value && typeof value === "object" && !Array.isArray(value) ? (value as JsonObject) : { result: value };
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }], structuredContent: structured };
};

const pick = (args: JsonObject, keys: string[]) =>
  Object.fromEntries(keys.filter((k) => args[k] !== undefined).map((k) => [k, args[k]]));

/** The receipt id an action returned, lifted to the top so agents see it. */
function withReceipt(value: unknown): unknown {
  if (!value || typeof value !== "object" || Array.isArray(value)) return value;
  const obj = value as JsonObject;
  const nested = obj.receipt && typeof obj.receipt === "object" ? (obj.receipt as JsonObject) : undefined;
  const receiptId = obj.receiptId ?? nested?.receiptId;
  return receiptId === undefined || "receiptId" in obj ? value : { receiptId, ...obj };
}

function placement(value: unknown): string | JsonObject {
  if (value === undefined) return "bottom-right";
  if (value && typeof value === "object") return value as JsonObject;
  const slot = normalizePlacement(String(value));
  if (!slot) throw new Error(`Unknown placement: ${String(value)}`);
  return slot;
}

/** This Mac's daemon, through the same host resolution and auth as the hosts toolset. */
function localDaemon(): DaemonCaller {
  const host = resolveHost("local");
  return { daemonCall: (method, params, timeoutMs) => callHost(host, method, params, timeoutMs) };
}

export async function callWindowTool(name: string, args: JsonObject): Promise<ToolResult> {
  const client = localDaemon();
  const call = (method: string, params?: JsonObject, timeoutMs?: number) => client.daemonCall(method, params, timeoutMs);

  switch (name) {
    case "windows_search": {
      if (typeof args.query !== "string" || !args.query) throw new Error("windows_search needs a query");
      const sources = Array.isArray(args.sources) && args.sources.length
        ? args.sources.map(String)
        : args.deep === true ? ["all"] : undefined;
      const ranked = await searchWithClient(client, args.query, sources ? { sources } : {});
      return text({
        results: ranked.map((r) => ({
          wid: r.window.wid,
          app: r.window.app,
          title: r.window.title,
          score: r.score,
          reasons: r.reasons,
          ...(r.tabs.length ? { tabs: r.tabs } : {}),
          ...(r.window.ocrSnippet ? { ocrSnippet: r.window.ocrSnippet } : {}),
        })),
      });
    }

    case "windows_place": {
      const spec = placement(args.placement);
      const dryRun = args.dryRun === true;
      if (args.wid !== undefined) {
        const params = { ...pick(args, ["wid", "display"]), placement: spec, ...(dryRun ? { dryRun } : {}) };
        return text(withReceipt(await call("windows.place", params, 15_000)));
      }
      if (typeof args.query !== "string" || !args.query) throw new Error("windows_place needs a wid or a query");
      if (typeof spec !== "string") throw new Error("Place by query takes a placement slot; use wid for a fractions placement");
      const placed = await placeWithClient(client, args.query, spec, dryRun);
      return text(placed ? withReceipt(placed) : { status: "not-found", query: args.query });
    }

    case "windows_focus":
      if (args.wid === undefined && typeof args.session !== "string") throw new Error("windows_focus needs a wid or a session");
      return text(await call("windows.focus", pick(args, ["wid", "session"])));

    case "layers_list":
      return text(await call("layers.list"));

    case "layers_switch": {
      const mode = typeof args.mode === "string" ? { mode: args.mode } : {};
      if (typeof args.index === "number") return text(await call("layers.activate", { index: args.index, ...mode }));
      if (typeof args.layer !== "string" || !args.layer) throw new Error("layers_switch needs a layer or an index");
      const target = layerTarget(args.layer);
      if ("error" in target) throw new Error(target.error);
      const params = "index" in target ? { index: target.index } : { name: target.name };
      return text(await call("layers.activate", { ...params, ...mode }));
    }

    case "history_undo":
      return text(withReceipt(await call("history.undo", { ...pick(args, ["receiptId", "requestId", "wid", "steps", "dryRun"]), source: "mcp" }, 15_000)));

    case "views_list":
      return text({ views: await call("views.list") });

    case "views_save":
      if (typeof args.host !== "string" || typeof args.app !== "string") throw new Error("views_save needs a host and an app");
      return text(await call("views.save", pick(args, ["host", "app", "name", "id", "width", "height"])));

    case "views_open":
      if (typeof args.id !== "string" || !args.id) throw new Error("views_open needs an id");
      return text(await call("views.open", { id: args.id }, 45_000));

    case "views_remove":
      if (typeof args.id !== "string" || !args.id) throw new Error("views_remove needs an id");
      return text(await call("views.remove", { id: args.id }));
  }
  throw new Error(`Unknown tool: ${name}`);
}

export const windowsToolset: Toolset = {
  name: "windows",
  title: "Lattices windows",
  tools: WINDOW_TOOLS,
  instructions: [
    "windows: this Mac's window controls. windows_search first (deep: true only when it misses), then windows_place / windows_focus by wid.",
    "windows: windows_place returns a receiptId; history_undo with it puts the window back. layers_list and layers_switch move between workspace layers.",
    "windows: views_save keeps an app on another host (e.g. Spotify on archie) by id; views_open shows it as its own window here and returns that window's id.",
  ],
  async callTool(name, args) {
    try {
      return await callWindowTool(name, args);
    } catch (err) {
      return toolError(err);
    }
  },
};
