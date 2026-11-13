// The `hosts` toolset (LAT-013 phase 4): every tool takes a `host`, so one
// agent can look at and drive any lattices machine -- the local Mac daemon, or
// a Linux machine running lattices-host on the tailnet.

import { readFileSync } from "node:fs";
import {
  callHost,
  configuredHosts,
  discoverTailnetHosts,
  hostStatuses,
  resolveHost,
  type HostEntry,
} from "../../../hosts.ts";
import { toolError, type JsonObject, type ToolDefinition, type ToolResult, type Toolset } from "../../types.ts";

const hostProp = {
  host: {
    type: "string",
    description: "Host name from hosts_list (e.g. `archie`), an address, or `local` (default) for this machine's daemon.",
  },
};

const targetProps = {
  wid: { type: "number", description: "Window id from host_windows" },
  app: { type: "string", description: "App or window class substring" },
  session: { type: "string", description: "Lattices session name" },
};

const object = (properties: JsonObject, required: string[] = []): JsonObject => ({
  type: "object",
  properties: { ...hostProp, ...properties },
  required,
  additionalProperties: false,
});

const readOnly = { readOnlyHint: true, openWorldHint: true };
const mutating = { readOnlyHint: false, destructiveHint: false, openWorldHint: true };

export const HOST_TOOLS: readonly ToolDefinition[] = [
  {
    name: "hosts_list",
    title: "List lattices hosts",
    description:
      "List the lattices hosts this agent can reach: the local daemon, hosts in ~/.lattices/hosts.json or LATTICES_HOSTS, and with discover: true your own tailnet devices answering on port 9399. Shows reachability, platform and capabilities.",
    inputSchema: {
      type: "object",
      properties: { discover: { type: "boolean", description: "Also probe your own online tailnet devices" } },
      additionalProperties: false,
    },
    annotations: readOnly,
  },
  {
    name: "host_describe",
    title: "Describe a host",
    description: "What a host is and can do: platform, displays, capabilities and methods (host.describe).",
    inputSchema: object({}),
    annotations: readOnly,
  },
  {
    name: "host_windows",
    title: "List a host's windows",
    description: "Windows on a host, with wid, app, title and frame. Pass query to search by title, app or session.",
    inputSchema: object({ query: { type: "string", description: "Optional search text" } }),
    annotations: readOnly,
  },
  {
    name: "host_screenshot",
    title: "See a host's screen",
    description: "A JPEG of a host's display or one window, scaled to maxWidth. Returns the image.",
    inputSchema: object({
      wid: { type: "number", description: "Capture this window instead of the display" },
      displayIndex: { type: "number", description: "Display to capture (default: focused display)" },
      maxWidth: { type: "number", description: "Width cap in pixels (default 1280)" },
    }),
    annotations: readOnly,
  },
  {
    name: "host_read",
    title: "Read text on a host's screen",
    description: "OCR a window or display on a host. Returns text lines with screen boxes; pass find to locate text and get a click point.",
    inputSchema: object({
      ...targetProps,
      displayIndex: { type: "number", description: "Read a whole display" },
      find: { type: "string", description: "Text to locate (tolerates OCR misreads)" },
    }),
    annotations: readOnly,
  },
  {
    name: "host_place",
    title: "Place a window on a host",
    description: "Move and resize a window: left, right, top-left, center, maximize, left-third, grid:3x2:0,1, or {kind:'fractions',x,y,w,h}.",
    inputSchema: object(
      {
        ...targetProps,
        placement: { description: "Placement shorthand or typed object" },
        display: { type: "number", description: "Target display index" },
      },
      ["placement"]
    ),
    annotations: mutating,
  },
  {
    name: "host_focus",
    title: "Focus a window on a host",
    description: "Bring a window to the front on a host.",
    inputSchema: object(targetProps),
    annotations: mutating,
  },
  {
    name: "host_act",
    title: "Click, type or press keys on a host",
    description:
      "Input on a host, executed for real. action: click (x,y or wid+xRatio/yRatio; button, count), type (text, enter; session for tmux), key (key or shortcut like ctrl+shift+p), scroll (x,y,dy,dx), drag (fromX,fromY,toX,toY).",
    inputSchema: object(
      {
        action: { type: "string", enum: ["click", "type", "key", "scroll", "drag"] },
        x: { type: "number" },
        y: { type: "number" },
        xRatio: { type: "number" },
        yRatio: { type: "number" },
        wid: { type: "number" },
        button: { type: "string", enum: ["left", "right", "middle"] },
        count: { type: "number" },
        text: { type: "string" },
        enter: { type: "boolean" },
        session: { type: "string" },
        key: { type: "string" },
        shortcut: { type: "string" },
        dx: { type: "number" },
        dy: { type: "number" },
        fromX: { type: "number" },
        fromY: { type: "number" },
        toX: { type: "number" },
        toY: { type: "number" },
      },
      ["action"]
    ),
    annotations: { ...mutating, destructiveHint: true },
  },
  {
    name: "host_call",
    title: "Call any method on a host",
    description: "Raw daemon call on a host: any method from host_describe with its params. Old method names work as aliases.",
    inputSchema: object(
      { method: { type: "string" }, params: { type: "object", description: "Method params" } },
      ["method"]
    ),
    annotations: { ...mutating, destructiveHint: true },
  },
];

const text = (value: unknown): ToolResult => {
  const structured = value && typeof value === "object" && !Array.isArray(value) ? (value as JsonObject) : { result: value };
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }], structuredContent: structured };
};

const pick = (args: JsonObject, keys: string[]) =>
  Object.fromEntries(keys.filter((k) => args[k] !== undefined).map((k) => [k, args[k]]));

const ACT_METHODS: Record<string, { method: string; keys: string[] }> = {
  click: { method: "computer.click", keys: ["x", "y", "xRatio", "yRatio", "wid", "button", "count"] },
  type: { method: "computer.typeText", keys: ["text", "enter", "session", "wid"] },
  key: { method: "computer.hotkey", keys: ["key", "shortcut", "wid"] },
  scroll: { method: "computer.scroll", keys: ["x", "y", "dx", "dy"] },
  drag: { method: "computer.drag", keys: ["fromX", "fromY", "toX", "toY"] },
};

let discovered: HostEntry[] = [];

function knownHosts(): HostEntry[] {
  const configured = configuredHosts();
  const names = new Set(configured.map((h) => h.name));
  return [...configured, ...discovered.filter((h) => !names.has(h.name))];
}

export async function callHostTool(name: string, args: JsonObject): Promise<ToolResult> {
  if (name === "hosts_list") {
    if (args.discover === true) discovered = await discoverTailnetHosts();
    return text({ hosts: await hostStatuses(knownHosts()) });
  }

  const host = resolveHost(typeof args.host === "string" ? args.host : undefined, knownHosts());
  const call = (method: string, params?: JsonObject, timeoutMs?: number) => callHost(host, method, params, timeoutMs);

  switch (name) {
    case "host_describe":
      return text(await call("host.describe"));

    case "host_windows":
      return text(
        typeof args.query === "string" && args.query
          ? await call("windows.search", { query: args.query })
          : await call("windows.list")
      );

    case "host_screenshot": {
      const params = { ...pick(args, ["wid", "displayIndex"]), maxWidth: args.maxWidth ?? 1280 };
      try {
        const shot = (await call("capture.still", params, 30_000)) as { data: string; width: number; height: number };
        return {
          content: [
            { type: "image", data: shot.data, mimeType: "image/jpeg" },
            { type: "text", text: `${host.name}: ${shot.width}x${shot.height}` },
          ],
        };
      } catch (err) {
        // A Mac daemon has no capture.still; its captures are files on that Mac.
        if ((err as Error).message !== "Unknown method: capture.still" || host.source !== "local") throw err;
        const method = args.wid !== undefined ? "capture.screenshotWindow" : "capture.screenshotDisplay";
        const shot = (await call(method, { ...pick(args, ["wid", "displayIndex"]), clipboard: false, source: "mcp" }, 30_000)) as { path?: string; artifact?: { path?: string } };
        const path = shot.path ?? shot.artifact?.path;
        if (!path) return text(shot);
        return { content: [{ type: "image", data: readFileSync(path).toString("base64"), mimeType: "image/png" }, { type: "text", text: path }] };
      }
    }

    case "host_read": {
      const region = pick(args, ["wid", "app", "session", "displayIndex"]);
      if (typeof args.find === "string" && args.find) return text(await call("ocr.find", { text: args.find, ...region }, 45_000));
      return text(await call("ocr.read", region, 45_000));
    }

    case "host_place":
      return text(await call("windows.place", pick(args, ["wid", "app", "session", "placement", "display"]), 15_000));

    case "host_focus":
      return text(await call("windows.focus", pick(args, ["wid", "app", "session"])));

    case "host_act": {
      const spec = ACT_METHODS[String(args.action)];
      if (!spec) throw new Error(`Unknown action: ${String(args.action)}. Use click, type, key, scroll or drag.`);
      return text(await call(spec.method, { ...pick(args, spec.keys), treatment: "execute" }, 15_000));
    }

    case "host_call": {
      if (typeof args.method !== "string") throw new Error("host_call needs a method");
      const params = args.params && typeof args.params === "object" ? (args.params as JsonObject) : {};
      return text(await call(args.method, params, 60_000));
    }
  }
  throw new Error(`Unknown tool: ${name}`);
}

export const hostsToolset: Toolset = {
  name: "hosts",
  title: "Lattices hosts",
  tools: HOST_TOOLS,
  instructions: [
    "hosts: every tool takes `host`. Start with hosts_list (discover: true finds your tailnet machines), then host_describe to see what a host can do.",
    "hosts: host_screenshot to look, host_read to find text and its click point, host_act to click/type/press keys (it executes), host_place to arrange windows.",
  ],
  async callTool(name, args) {
    try {
      return await callHostTool(name, args);
    } catch (err) {
      return toolError(err);
    }
  },
};
