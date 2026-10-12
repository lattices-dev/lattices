import { hostname as osHostname } from "node:os";
import * as capture from "./capture.ts";
import * as desktop from "./desktop.ts";
import { registerVirtualSpaceEndpoints } from "./virtual-space.ts";
import { registerLayerEndpoints } from "./layers.ts";
import { run } from "./exec.ts";
import * as hypr from "./hyprland.ts";
import * as input from "./input.ts";
import * as live from "./live.ts";
import { bringCursorHome, type CursorHomeDependencies } from "./cursor-home.ts";
import * as ocr from "./ocr.ts";
import * as record from "./record.ts";
import { closeSync, mkdirSync, openSync, readSync, realpathSync, statSync } from "node:fs";
import { sep } from "node:path";
import { parsePlacement, type Rect } from "./placement.ts";
import { Router, RouterError, bool, num, requireStr, str, type Json, type Params } from "./router.ts";
import * as tmux from "./tmux.ts";
import { capabilities, capabilityHealth, refreshCapabilities } from "./host-capabilities.ts";
export { capabilities, refreshCapabilities } from "./host-capabilities.ts";

import { BUILD_IDENTITY, VERSION } from "./build-info.ts";
export { VERSION } from "./build-info.ts";

export interface HostContext {
  bindHost: string;
  /** This machine's name on the tailnet, when Tailscale is up. */
  tailnetName?: string;
  startedAt: number;
  clientCount: () => number;
  emit?: (event: string, data: unknown) => void;
}

const asJson = (value: unknown) => value as Json;

const targetParams = [
  { name: "wid", type: "uint32", description: "Window id (from windows.list)" },
  { name: "session", type: "string", description: "Lattices session tag in the window title" },
  { name: "app", type: "string", description: "App (window class) substring" },
  { name: "title", type: "string", description: "Title substring, with app" },
];

const treatmentParams = [
  { name: "treatment", type: "string", description: "`stage` (default) returns the plan; `execute` acts" },
  { name: "dryRun", type: "bool", description: "Plan without acting, whatever the treatment" },
];

function executes(params: Params) {
  return params.treatment === "execute" && bool(params, "dryRun") !== true;
}

function staged(plan: Record<string, unknown>): Json {
  return asJson({ ok: true, status: "staged", executed: false, ...plan });
}

/** A point in layout coordinates from x/y or a window plus xRatio/yRatio. */
async function resolvePoint(params: Params) {
  const snap = await desktop.snapshot();
  const extent = input.layoutExtent(snap.displays);
  const x = num(params, "x");
  const y = num(params, "y");
  if (x !== undefined && y !== undefined) return { x, y, extent, window: null as desktop.Window | null };
  const xr = num(params, "xRatio");
  const yr = num(params, "yRatio");
  if (xr === undefined || yr === undefined) throw RouterError.missingParam("x/y or xRatio/yRatio");
  const { window } = await desktop.resolveTarget(params);
  return {
    x: window.frame.x + xr * window.frame.w,
    y: window.frame.y + yr * window.frame.h,
    extent,
    window,
  };
}

function regionFrom(params: Params): Rect | undefined {
  const x = num(params, "x");
  const y = num(params, "y");
  const w = num(params, "width") ?? num(params, "w");
  const h = num(params, "height") ?? num(params, "h");
  if ([x, y, w, h].every((v) => v !== undefined)) return { x: x!, y: y!, w: w!, h: h! };
  return undefined;
}

async function shoot(params: Params, region: Rect | undefined, output?: string) {
  const format = params.format === "jpeg" || params.format === "jpg" ? "jpeg" : "png";
  const bytes = await capture.grab({
    region,
    output,
    format,
    quality: num(params, "quality"),
    scale: num(params, "scale"),
    cursor: bool(params, "cursor") ?? false,
  });
  const path = capture.save(bytes, format, str(params, "filename"));
  const size = capture.imageSize(bytes);
  const result: Record<string, unknown> = {
    ok: true,
    path,
    format,
    bytes: bytes.length,
    width: size?.width ?? null,
    height: size?.height ?? null,
    region: region ?? null,
  };
  if (bool(params, "inline")) result.data = bytes.toString("base64");
  return result;
}

export function registerEndpoints(router: Router, ctx: HostContext, cursorDeps?: CursorHomeDependencies) {
  registerLayerEndpoints(router, ctx.emit);
  router.register({
    method: "mouse.home",
    description: "Bring the cursor to the focused real monitor",
    access: "mutate",
    capability: "spaces.read",
    returns: "Object with ok, monitor, x and y",
    handler: async () => asJson(await bringCursorHome(cursorDeps)),
  });
  // ── Host ────────────────────────────────────────────────────────────
  router.register({
    method: "daemon.status",
    description: "Health check and basic stats",
    access: "read",
    returns: "Object with uptime, clientCount, version, windowCount, tmuxSessionCount, frontmostWid",
    handler: async () => {
      const snap = capabilities.has("windows.read") ? await desktop.snapshot() : null;
      const sessions = capabilities.has("sessions.tmux") ? await tmux.listSessions() : [];
      return asJson({
        uptime: (Date.now() - ctx.startedAt) / 1000,
        clientCount: ctx.clientCount(),
        version: VERSION,
        build: BUILD_IDENTITY,
        platform: "linux",
        windowCount: snap?.windows.length ?? 0,
        tmuxSessionCount: sessions.length,
        frontmostWid: snap?.windows.find((w) => w.isFocused)?.wid ?? null,
      });
    },
  });

  router.register({
    method: "api.schema",
    description: "Machine-readable methods this host serves, plus old-name aliases",
    access: "read",
    returns: "Object with version, models, methods and aliases",
    handler: () => router.schema(),
  });

  router.register({
    method: "host.describe",
    description: "What this host is and can do: platform, displays, capabilities and methods (LAT-013)",
    access: "read",
    returns: "Object with platform, hostname, displays, capabilities, methods",
    handler: async () => {
      if (!capabilities.has("spaces.read") && capabilityHealth["spaces.read"]?.available === false && hypr.available()) {
        await refreshCapabilities();
      }
      let displays: desktop.Display[] = [];
      if (capabilities.has("spaces.read")) {
        try { displays = (await desktop.snapshot()).displays; }
        catch (error) {
          const reason = (error as Error).message;
          for (const name of ["windows.read", "windows.place", "spaces.read", "apps.open", "capture.still", "capture.live", "input.pointer", "ocr", "capture.record"]) {
            capabilities.delete(name);
            capabilityHealth[name] = { available: false, reason };
          }
        }
      }
      return asJson({
        platform: "linux",
        compositor: hypr.available() ? "hyprland" : null,
        hostname: osHostname(),
        tailnetName: ctx.tailnetName ?? null,
        version: VERSION,
        build: BUILD_IDENTITY,
        address: ctx.bindHost,
        displays,
        capabilities: [...capabilities].sort(),
        capabilityHealth,
        eventStream: hypr.getEventStreamHealth(),
        methods: router.available().map((e) => e.method).sort(),
        keyMapping: "command and control map to ctrl; option to alt; super, meta and win to the logo key",
      });
    },
  });

  // Answered by the server per connection (server.ts); registered here so
  // api.schema and host.describe list them.
  const connectionScoped = () => {
    throw new RouterError("events.* acts on a WebSocket connection; send it over one");
  };
  router.register({
    method: "events.subscribe",
    description: "Receive only these events on this connection (windows.changed, spaces.changed); `*` for all, the default",
    access: "read",
    params: [{ name: "events", type: "[string]", description: "Event names, or [\"*\"]" }],
    returns: "Object with ok and the connection's events",
    handler: connectionScoped,
  });
  router.register({
    method: "events.unsubscribe",
    description: "Stop receiving these events on this connection; no list stops all",
    access: "read",
    params: [{ name: "events", type: "[string]", description: "Event names; omit for all" }],
    returns: "Object with ok and the connection's events",
    handler: connectionScoped,
  });

  // ── Windows ─────────────────────────────────────────────────────────
  router.register({
    method: "windows.list",
    description: "List mapped windows on every workspace",
    access: "read",
    capability: "windows.read",
    returns: "Array of Window",
    handler: async () => asJson((await desktop.snapshot()).windows),
  });

  router.register({
    method: "windows.get",
    description: "Get one window by wid",
    access: "read",
    capability: "windows.read",
    params: [{ name: "wid", type: "uint32", required: true, description: "Window id" }],
    returns: "Window",
    handler: async (params) => {
      if (num(params, "wid") === undefined) throw RouterError.missingParam("wid");
      return asJson((await desktop.resolveTarget(params)).window);
    },
  });

  router.register({
    method: "windows.search",
    description: "Search windows by title, app and session tag",
    access: "read",
    capability: "windows.read",
    params: [
      { name: "query", type: "string", required: true, description: "Text to match" },
      { name: "limit", type: "int", description: "Max results (default 50)" },
    ],
    returns: "Array of Window with score and matchSource",
    handler: async (params) =>
      desktop.searchWindows((await desktop.snapshot()).windows, requireStr(params, "query"), num(params, "limit") ?? 50),
  });

  router.register({
    method: "windows.resolve",
    description: "Resolve a target and optional placement without moving anything",
    access: "read",
    capability: "windows.read",
    params: [...targetParams, { name: "placement", type: "string|object", description: "Optional placement" }, { name: "display", type: "int", description: "Target display index" }],
    returns: "Object with window and optional target frame",
    handler: async (params) => {
      const { window, snap } = await desktop.resolveTarget(params);
      if (params.placement == null) return asJson({ window });
      const display = snap.displays[num(params, "display") ?? window.displayIndex];
      if (!display) throw RouterError.notFound(`display ${params.display}`);
      const plan = await desktop.place(window, parsePlacement(params.placement), display, true);
      return asJson({ window, display: display.displayIndex, frame: plan.target });
    },
  });

  router.register({
    method: "windows.focus",
    description: "Focus a window, switching workspace if needed",
    access: "mutate",
    capability: "windows.read",
    params: targetParams,
    returns: "Object with ok and the focused window",
    handler: async (params) => {
      const { window } = await desktop.resolveTarget(params);
      await hypr.apply([{ op: "focus", address: window.address }]);
      return asJson({ ok: true, window });
    },
  });

  router.register({
    method: "windows.place",
    description: "Place a window with a typed placement (tiles, thirds, grid:CxR:C,R, fractions); floats it first",
    access: "mutate",
    capability: "windows.place",
    params: [
      ...targetParams,
      { name: "display", type: "int", description: "Target display index" },
      { name: "placement", type: "string|object", required: true, description: "Placement shorthand or typed object" },
      { name: "dryRun", type: "bool", description: "Plan without moving" },
    ],
    returns: "Receipt with target, placement, frame, status and trace",
    handler: async (params) => {
      if (params.placement == null) throw RouterError.missingParam("placement");
      const fractions = parsePlacement(params.placement);
      const { window, snap } = await desktop.resolveTarget(params);
      const displayIndex = num(params, "display") ?? window.displayIndex;
      const display = snap.displays[displayIndex];
      if (!display) throw RouterError.notFound(`display ${displayIndex}`);
      const dryRun = bool(params, "dryRun") ?? false;
      const trace: string[] = [];
      if (display.displayIndex !== window.displayIndex && !dryRun) {
        trace.push(...(await hypr.apply([{ op: "toWorkspace", address: window.address, workspace: display.currentSpaceId }])));
      }
      const plan = await desktop.place(window, fractions, display, dryRun);
      trace.push(...plan.commands);
      const after = dryRun ? null : (await desktop.resolveTarget({ wid: window.wid })).window;
      return asJson({
        ok: true,
        status: dryRun ? "planned" : "ok",
        target: { wid: window.wid, app: window.app, title: window.title },
        placement: params.placement,
        display: display.displayIndex,
        frame: plan.target,
        after: after?.frame ?? null,
        verified: after ? Math.abs(after.frame.x - plan.target.x) <= 2 && Math.abs(after.frame.y - plan.target.y) <= 2 : null,
        trace,
      });
    },
  });

  router.register({
    method: "windows.move",
    description: "Move a window to another display or workspace, optionally into a placement",
    access: "mutate",
    capability: "windows.place",
    params: [
      ...targetParams,
      { name: "display", type: "int", description: "Target display index" },
      { name: "space", type: "int", description: "Target workspace id" },
      { name: "placement", type: "string|object", description: "Optional placement on arrival" },
      { name: "dryRun", type: "bool", description: "Plan without moving" },
    ],
    returns: "Receipt with target, destination and trace",
    handler: async (params) => {
      const hasTarget = ["wid", "session", "app"].some((k) => params[k] != null);
      if (!hasTarget) throw new RouterError("windows.move requires a wid, session or app target");
      const space = num(params, "space");
      const displayIndex = num(params, "display");
      if (space === undefined && displayIndex === undefined && params.placement == null) {
        throw new RouterError("windows.move needs a display, space or placement");
      }
      const { window, snap } = await desktop.resolveTarget(params);
      const display = displayIndex !== undefined ? snap.displays[displayIndex] : undefined;
      if (displayIndex !== undefined && !display) throw RouterError.notFound(`display ${displayIndex}`);
      const workspace = space ?? display?.currentSpaceId;
      const dryRun = bool(params, "dryRun") ?? false;
      const trace: string[] = [];
      if (workspace !== undefined && !window.spaceIds.includes(workspace)) {
        const ops: hypr.Op[] = [{ op: "toWorkspace", address: window.address, workspace }];
        trace.push(...(dryRun ? await hypr.plan(ops) : await hypr.apply(ops)));
      }
      if (params.placement != null) {
        const dest = display ?? snap.displays[window.displayIndex];
        const plan = await desktop.place(window, parsePlacement(params.placement), dest, dryRun);
        trace.push(...plan.commands);
      }
      return asJson({ ok: true, status: dryRun ? "planned" : "ok", target: { wid: window.wid }, space: workspace ?? null, trace });
    },
  });

  router.register({
    method: "spaces.list",
    description: "Displays with their workspaces (Hyprland workspaces stand in for macOS Spaces)",
    access: "read",
    capability: "spaces.read",
    returns: "Array of Display",
    handler: async () => asJson((await desktop.snapshot()).displays),
  });

  router.register({
    method: "desktop.snapshot",
    description: "Front window, displays and tmux sessions in one call",
    access: "read",
    capability: "windows.read",
    returns: "Object with frontWindow, displays, windows, sessions",
    handler: async () => {
      const snap = await desktop.snapshot();
      return asJson({
        frontWindow: snap.windows.find((w) => w.isFocused) ?? null,
        displays: snap.displays,
        windows: snap.windows,
        sessions: capabilities.has("sessions.tmux") ? await tmux.listSessions() : [],
        platform: "linux",
      });
    },
  });

  // ── Capture ─────────────────────────────────────────────────────────
  const captureParams = [
    { name: "format", type: "string", description: "`png` (default) or `jpeg`" },
    { name: "quality", type: "int", description: "JPEG quality, 0-100" },
    { name: "scale", type: "double", description: "Output scale, e.g. 0.5" },
    { name: "cursor", type: "bool", description: "Include the pointer" },
    { name: "inline", type: "bool", description: "Also return the image as base64 `data`" },
    { name: "filename", type: "string", description: "File name under ~/.lattices/captures" },
  ];

  router.register({
    method: "capture.screenshotDisplay",
    description: "Capture one display",
    access: "read",
    capability: "capture.still",
    params: [{ name: "displayIndex", type: "int", description: "Display index; defaults to the focused display" }, ...captureParams],
    returns: "Object with path, format, width, height and optional data",
    handler: async (params) => {
      const snap = await desktop.snapshot();
      const index = num(params, "displayIndex") ?? num(params, "display");
      const focusedMonitor = snap.monitors.find((m) => m.focused)?.name;
      const display = index !== undefined ? snap.displays[index] : snap.displays.find((d) => d.displayId === focusedMonitor) ?? snap.displays[0];
      if (!display) throw RouterError.notFound(`display ${index}`);
      return asJson({ ...(await shoot(params, undefined, display.displayId)), displayIndex: display.displayIndex });
    },
  });

  router.register({
    method: "capture.screenshotWindow",
    description: "Capture a window's frame (what is on screen there)",
    access: "read",
    capability: "capture.still",
    params: [...targetParams, ...captureParams],
    returns: "Object with path, format, width, height and optional data",
    handler: async (params) => {
      const { window } = await desktop.resolveTarget(params);
      if (!window.isOnScreen) throw new RouterError(`window ${window.wid} is not on screen`);
      return asJson({ ...(await shoot(params, window.frame)), wid: window.wid });
    },
  });

  router.register({
    method: "capture.screenshotRegion",
    description: "Capture a rectangle, or a target window's frame when no rectangle is given",
    access: "read",
    capability: "capture.still",
    params: [
      { name: "x", type: "double", description: "Left edge" },
      { name: "y", type: "double", description: "Top edge" },
      { name: "width", type: "double", description: "Width (alias w)" },
      { name: "height", type: "double", description: "Height (alias h)" },
      ...targetParams,
      ...captureParams,
    ],
    returns: "Object with path, format, width, height and optional data",
    handler: async (params) => {
      const region = regionFrom(params) ?? (await desktop.resolveTarget(params)).window.frame;
      return asJson(await shoot(params, region));
    },
  });

  router.register({
    method: "capture.still",
    description: "A snapshot for remote viewers: JPEG bytes inline, scaled down to maxWidth",
    access: "read",
    capability: "capture.still",
    params: [
      { name: "displayIndex", type: "int", description: "Display index; defaults to the focused display" },
      { name: "wid", type: "uint32", description: "Capture this window instead" },
      { name: "maxWidth", type: "int", description: "Longest width in pixels (default 1440)" },
      { name: "quality", type: "int", description: "JPEG quality (default 70)" },
    ],
    returns: "Object with data (base64 JPEG), width, height",
    handler: async (params) => {
      const snap = await desktop.snapshot();
      const maxWidth = num(params, "maxWidth") ?? 1440;
      let region: Rect | undefined;
      let output: string | undefined;
      let width: number;
      if (num(params, "wid") !== undefined) {
        const { window } = await desktop.resolveTarget(params);
        region = window.frame;
        width = window.frame.w;
      } else {
        const index = num(params, "displayIndex");
        const focusedMonitor = snap.monitors.find((m) => m.focused)?.name;
        const display = index !== undefined ? snap.displays[index] : snap.displays.find((d) => d.displayId === focusedMonitor) ?? snap.displays[0];
        if (!display) throw RouterError.notFound(`display ${index}`);
        output = display.displayId;
        width = display.frame.w * display.scale;
      }
      const scale = Math.min(1, maxWidth / Math.max(1, width));
      const bytes = await capture.grab({ region, output, format: "jpeg", quality: num(params, "quality") ?? 70, scale });
      const size = capture.imageSize(bytes);
      return asJson({ ok: true, format: "jpeg", width: size?.width ?? null, height: size?.height ?? null, data: bytes.toString("base64") });
    },
  });

  router.register({
    method: "capture.live",
    description: "Start (or report) a wayvnc live view on this host's address; `stop: true` ends it",
    access: "mutate",
    capability: "capture.live",
    params: [
      { name: "stop", type: "bool", description: "Stop the live view" },
      { name: "port", type: "int", description: "VNC port (default 5900)" },
      { name: "displayIndex", type: "int", description: "Display to share; defaults to wayvnc's choice" },
    ],
    returns: "Object with running, host, port and a vnc:// url",
    handler: async (params) => {
      if (bool(params, "stop")) return asJson(live.stop());
      let output: string | undefined;
      const index = num(params, "displayIndex");
      if (index !== undefined) output = (await desktop.snapshot()).displays[index]?.displayId;
      return asJson(await live.start(ctx.bindHost, num(params, "port") ?? 5900, output));
    },
  });

  // ── Computer use ────────────────────────────────────────────────────
  const pointParams = [
    { name: "x", type: "double", description: "Absolute x in layout coordinates" },
    { name: "y", type: "double", description: "Absolute y" },
    { name: "xRatio", type: "double", description: "Window-relative x (0-1), with a window target" },
    { name: "yRatio", type: "double", description: "Window-relative y (0-1)" },
    ...targetParams,
  ];

  const registerClick = (method: string, description: string, fixed: { button?: "left" | "right"; count?: number }) =>
    router.register({
      method,
      description: `${description}. Stages by default; acts with treatment: "execute"`,
      access: "mutate",
      capability: "input.pointer",
      params: [
        ...pointParams,
        { name: "button", type: "string", description: "`left`, `right` or `middle`" },
        { name: "count", type: "int", description: "Click count (max 8)" },
        ...treatmentParams,
      ],
      returns: "Receipt with point, button, count and status",
      handler: async (params) => {
        const point = await resolvePoint(params);
        const button = (fixed.button ?? (str(params, "button") as "left" | "right" | "middle" | undefined) ?? "left") as "left";
        const count = Math.min(8, fixed.count ?? num(params, "count") ?? 1);
        const plan = { point: { x: Math.round(point.x), y: Math.round(point.y) }, button, count, wid: point.window?.wid ?? null };
        if (!executes(params)) return staged(plan);
        await input.click(point.x, point.y, point.extent, button, count, num(params, "delayMs") ?? 80);
        return asJson({ ok: true, status: "executed", executed: true, ...plan });
      },
    });
  registerClick("computer.click", "Click a point", {});
  registerClick("computer.doubleClick", "Double-click a point", { count: 2 });
  registerClick("computer.rightClick", "Right-click a point", { button: "right" });

  router.register({
    method: "computer.drag",
    description: 'Drag between two points. Stages by default; acts with treatment: "execute"',
    access: "mutate",
    capability: "input.pointer",
    params: [
      { name: "fromX", type: "double", required: true, description: "Start x" },
      { name: "fromY", type: "double", required: true, description: "Start y" },
      { name: "toX", type: "double", required: true, description: "End x" },
      { name: "toY", type: "double", required: true, description: "End y" },
      ...treatmentParams,
    ],
    returns: "Receipt with from, to and status",
    handler: async (params) => {
      const [fromX, fromY, toX, toY] = ["fromX", "fromY", "toX", "toY"].map((k) => {
        const v = num(params, k);
        if (v === undefined) throw RouterError.missingParam(k);
        return v;
      });
      const plan = { from: { x: fromX, y: fromY }, to: { x: toX, y: toY } };
      if (!executes(params)) return staged(plan);
      const extent = input.layoutExtent((await desktop.snapshot()).displays);
      await input.drag(plan.from, plan.to, extent);
      return asJson({ ok: true, status: "executed", executed: true, ...plan });
    },
  });

  router.register({
    method: "computer.scroll",
    description: 'Scroll, optionally at a point. Stages by default; acts with treatment: "execute"',
    access: "mutate",
    capability: "input.pointer",
    params: [
      { name: "x", type: "double", description: "Point x (optional)" },
      { name: "y", type: "double", description: "Point y (optional)" },
      { name: "dx", type: "double", description: "Horizontal scroll in wheel units (default 0)" },
      { name: "dy", type: "double", description: "Vertical scroll in wheel units; positive scrolls down (default 0)" },
      ...treatmentParams,
    ],
    returns: "Receipt with deltas and status",
    handler: async (params) => {
      const plan = { x: num(params, "x") ?? null, y: num(params, "y") ?? null, dx: num(params, "dx") ?? 0, dy: num(params, "dy") ?? 0 };
      if (!executes(params)) return staged(plan);
      const extent = input.layoutExtent((await desktop.snapshot()).displays);
      await input.scroll(plan.x ?? undefined, plan.y ?? undefined, plan.dx * 15, plan.dy * 15, extent);
      return asJson({ ok: true, status: "executed", executed: true, ...plan });
    },
  });

  router.register({
    method: "computer.aim",
    description: 'Move the pointer without clicking. Stages by default; acts with treatment: "execute"',
    access: "mutate",
    capability: "input.pointer",
    params: [...pointParams, ...treatmentParams],
    returns: "Receipt with point and status",
    handler: async (params) => {
      const point = await resolvePoint(params);
      const plan = { point: { x: Math.round(point.x), y: Math.round(point.y) } };
      if (!executes(params)) return staged(plan);
      await input.moveCursor(point.x, point.y, point.extent);
      return asJson({ ok: true, status: "executed", executed: true, ...plan });
    },
  });

  router.register({
    method: "computer.typeText",
    description:
      'Type text into a tmux session (send-keys) or the focused window (wtype). Enter only with enter: true. Stages by default; acts with treatment: "execute"',
    access: "mutate",
    capability: "input.keys",
    params: [
      { name: "text", type: "string", required: true, description: "Text to insert" },
      { name: "enter", type: "bool", description: "Press Enter afterwards" },
      { name: "session", type: "string", description: "tmux session or pane target; uses send-keys, no focus needed" },
      { name: "wid", type: "uint32", description: "Focus this window first, then type" },
      ...treatmentParams,
    ],
    returns: "Receipt with transport and status",
    handler: async (params) => {
      const text = typeof params.text === "string" ? params.text : undefined;
      if (text === undefined) throw RouterError.missingParam("text");
      const enter = bool(params, "enter") ?? false;
      const session = str(params, "session");
      const transport = session ? "tmux" : "wtype";
      const plan = { transport, target: session ?? params.wid ?? "focused", length: text.length, enter };
      if (!executes(params)) return staged(plan);
      if (session) {
        await tmux.sendText(session, text, enter);
      } else {
        if (num(params, "wid") !== undefined) {
          const { window } = await desktop.resolveTarget(params);
          await hypr.apply([{ op: "focus", address: window.address }]);
        }
        await input.typeText(text, enter);
      }
      return asJson({ ok: true, status: "executed", executed: true, ...plan });
    },
  });

  const keyHandler = (method: "computer.pressKey" | "computer.hotkey") => async (params: Params) => {
    let key = str(params, "key");
    let modifiers: string[] = Array.isArray(params.modifiers)
      ? params.modifiers.map(String)
      : typeof params.modifiers === "string"
        ? params.modifiers.split(/[+, ]+/).filter(Boolean)
        : [];
    const shortcut = str(params, "shortcut");
    if (!key && shortcut) {
      const parsed = input.parseShortcut(shortcut);
      key = parsed.key;
      modifiers = [...modifiers, ...parsed.modifiers];
    }
    if (!key) throw RouterError.missingParam(method === "computer.hotkey" ? "shortcut or key" : "key");
    const count = Math.min(20, num(params, "count") ?? 1);
    const args = input.wtypeKeyArgs(key, modifiers, count, num(params, "delayMs") ?? 80);
    const plan = { key, modifiers, count, wtype: args };
    if (!executes(params)) return staged(plan);
    if (num(params, "wid") !== undefined || str(params, "app")) {
      const { window } = await desktop.resolveTarget(params);
      await hypr.apply([{ op: "focus", address: window.address }]);
    }
    await run("wtype", args);
    return asJson({ ok: true, status: "executed", executed: true, ...plan });
  };
  const keyParams = [
    { name: "key", type: "string", description: "Key name or single character" },
    { name: "shortcut", type: "string", description: "e.g. ctrl+shift+p; command maps to ctrl" },
    { name: "modifiers", type: "array|string", description: "command, control, option, shift, super" },
    { name: "count", type: "int", description: "Repeat count (max 20)" },
    { name: "wid", type: "uint32", description: "Focus this window first" },
    { name: "app", type: "string", description: "Focus this app first" },
    ...treatmentParams,
  ];
  router.register({
    method: "computer.pressKey",
    description: 'Press one key. Stages by default; acts with treatment: "execute"',
    access: "mutate",
    capability: "input.keys",
    params: keyParams,
    returns: "Receipt with key, modifiers and status",
    handler: keyHandler("computer.pressKey"),
  });
  router.register({
    method: "computer.hotkey",
    description: 'Press a shortcut. Stages by default; acts with treatment: "execute"',
    access: "mutate",
    capability: "input.keys",
    params: keyParams,
    returns: "Receipt with key, modifiers and status",
    handler: keyHandler("computer.hotkey"),
  });

  router.register({
    method: "computer.observe",
    description: "Read what is on screen: a window or region's pixels through OCR (tesseract), plus the window under it",
    access: "read",
    capability: "ocr",
    params: [
      ...targetParams,
      { name: "x", type: "double", description: "Region left (with y, width, height)" },
      { name: "y", type: "double", description: "Region top" },
      { name: "width", type: "double", description: "Region width" },
      { name: "height", type: "double", description: "Region height" },
      { name: "image", type: "bool", description: "Also return the PNG as base64" },
    ],
    returns: "Object with text, window, region and optional image",
    handler: async (params) => {
      let region = regionFrom(params);
      let window: desktop.Window | null = null;
      if (!region) {
        window = (await desktop.resolveTarget(params)).window;
        region = window.frame;
      }
      const bytes = await capture.grab({ region, format: "png" });
      const text = await run("tesseract", ["stdin", "stdout", "--psm", "3"], { input: bytes, timeoutMs: 30_000 });
      return asJson({
        ok: true,
        text: text.trim(),
        window,
        region,
        ...(bool(params, "image") ? { image: bytes.toString("base64") } : {}),
      });
    },
  });

  // ── Sessions ────────────────────────────────────────────────────────
  router.register({
    method: "tmux.list",
    description: "tmux sessions with their panes; with includeOrphans, {all, orphans} like the Mac inventory",
    access: "read",
    capability: "sessions.tmux",
    params: [{ name: "includeOrphans", type: "bool", description: "Return {all, orphans}" }],
    returns: "Array of TmuxSession, or {all, orphans}",
    handler: async (params) => {
      const sessions = await tmux.listSessions();
      // This host does not track projects, so no session is an orphan.
      return bool(params, "includeOrphans") ? asJson({ all: sessions, orphans: [] }) : sessions;
    },
  });

  router.register({
    method: "sessions.launch",
    description: "Start (or find) a detached tmux session for a directory, named like the Mac names it",
    access: "mutate",
    capability: "sessions.tmux",
    params: [
      { name: "path", type: "string", required: true, description: "Project directory" },
      { name: "name", type: "string", description: "Session name; defaults to <basename>-<hash>" },
    ],
    returns: "Object with ok, session and created",
    handler: async (params) => asJson({ ok: true, ...(await tmux.launch(requireStr(params, "path"), str(params, "name"))) }),
  });

  router.register({
    method: "sessions.kill",
    description: "Kill a tmux session",
    access: "mutate",
    capability: "sessions.tmux",
    params: [{ name: "name", type: "string", required: true, description: "Session name" }],
    returns: "Object with ok",
    handler: async (params) => {
      await tmux.kill(requireStr(params, "name"));
      return { ok: true };
    },
  });

  router.register({
    method: "sessions.detach",
    description: "Detach clients from a tmux session",
    access: "mutate",
    capability: "sessions.tmux",
    params: [{ name: "name", type: "string", required: true, description: "Session name" }],
    returns: "Object with ok",
    handler: async (params) => {
      await tmux.detach(requireStr(params, "name"));
      return { ok: true };
    },
  });

  router.register({
    method: "terminals.capture",
    description: "Recent text from a tmux pane",
    access: "read",
    capability: "sessions.tmux",
    params: [
      { name: "session", type: "string", required: true, description: "tmux session or pane target" },
      { name: "lines", type: "int", description: "Lines of history (default 200)" },
    ],
    returns: "Object with text",
    handler: async (params) => asJson({ text: await tmux.capturePane(requireStr(params, "session"), num(params, "lines") ?? 200) }),
  });

  // ── Action support (LAT-013 phase 3) ────────────────────────────────
  const regionParams = [
    ...targetParams,
    { name: "x", type: "double", description: "Region left (with y, width, height)" },
    { name: "y", type: "double", description: "Region top" },
    { name: "width", type: "double", description: "Region width" },
    { name: "height", type: "double", description: "Region height" },
    { name: "displayIndex", type: "int", description: "Read a whole display" },
  ];

  /** A region from x/y/width/height, a display, or a window target (default: focused window). */
  async function resolveRegion(params: Params): Promise<{ region: Rect; output?: string; window: desktop.Window | null }> {
    const explicit = regionFrom(params);
    if (explicit) return { region: explicit, window: null };
    const index = num(params, "displayIndex");
    if (index !== undefined) {
      const display = (await desktop.snapshot()).displays[index];
      if (!display) throw RouterError.notFound(`display ${index}`);
      return { region: display.frame, output: display.displayId, window: null };
    }
    const { window } = await desktop.resolveTarget(params);
    return { region: window.frame, window };
  }

  async function readRegion(params: Params) {
    const { region, output, window } = await resolveRegion(params);
    // tesseract misreads small UI text at 1x ("Hetlo Renote"); a 2x capture fixes most of it.
    const scale = region.w * 2 <= 8000 ? 2 : 1;
    const png = await capture.grab({ region: output ? undefined : region, output, format: "png", scale });
    const size = capture.imageSize(png) ?? { width: region.w, height: region.h };
    return { read: await ocr.read(png, region, size.width, size.height), window, png };
  }

  router.register({
    method: "ocr.read",
    description: "OCR a window, region or display; returns lines with image and screen boxes",
    access: "read",
    capability: "ocr",
    params: [...regionParams, { name: "image", type: "bool", description: "Also return the PNG as base64" }],
    returns: "Object with fullText, blocks (text, confidence, frame, screenFrame), imageWidth, imageHeight, region",
    handler: async (params) => {
      const { read, window, png } = await readRegion(params);
      return asJson({ ...read, wid: window?.wid ?? null, ...(bool(params, "image") ? { image: png.toString("base64") } : {}) });
    },
  });

  router.register({
    method: "ocr.find",
    description: "Find text on screen; returns matching lines with screen bounds and a center point to click",
    access: "read",
    capability: "ocr",
    params: [
      { name: "text", type: "string", required: true, description: "Text to find; tolerates OCR misreads" },
      { name: "minScore", type: "double", description: "Minimum match score, 0-1 (default 0.75)" },
      ...regionParams,
    ],
    returns: "Object with matches (text, confidence, bounds, point), best first",
    handler: async (params) => {
      const text = requireStr(params, "text");
      const { read, window } = await readRegion(params);
      const matches = ocr.find(read.blocks, text, num(params, "minScore") ?? 0.75).map((line) => ({
        text: line.text,
        score: Number(line.score.toFixed(3)),
        confidence: line.confidence,
        bounds: line.screenFrame,
        point: { x: Math.round(line.screenFrame.x + line.screenFrame.w / 2), y: Math.round(line.screenFrame.y + line.screenFrame.h / 2) },
      }));
      return asJson({ text, matches, region: read.region, wid: window?.wid ?? null });
    },
  });

  router.register({
    method: "apps.open",
    description: "Launch a command through the compositor and wait for its window",
    access: "mutate",
    capability: "apps.open",
    params: [
      { name: "command", type: "string", required: true, description: "Command line, e.g. `firefox` or `foot -T notes`" },
      { name: "timeoutMs", type: "int", description: "How long to wait for a new window (default 8000)" },
    ],
    returns: "Object with ok and the new window, or window: null if none appeared in time",
    handler: async (params) => {
      const command = requireStr(params, "command");
      const before = new Set((await desktop.snapshot()).windows.map((w) => w.wid));
      await hypr.exec(command);
      const deadline = Date.now() + (num(params, "timeoutMs") ?? 8000);
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 150));
        const fresh = (await desktop.snapshot()).windows.find((w) => !before.has(w.wid));
        if (fresh) return asJson({ ok: true, window: fresh });
      }
      return asJson({ ok: true, window: null });
    },
  });

  router.register({
    method: "capture.record",
    description: "Record the screen as grim frames encoded by ffmpeg: action start | pause | resume | stop | status",
    access: "mutate",
    capability: "capture.record",
    params: [
      { name: "action", type: "string", required: true, description: "start, pause, resume, stop or status" },
      ...regionParams,
      { name: "fps", type: "int", description: "Frames per second, 1-15 (default 5)" },
      { name: "format", type: "string", description: "`mp4` (default) or `mov`" },
    ],
    returns: "Recording status; stop returns the video path, frame count and duration",
    handler: async (params) => {
      switch (params.action) {
        case "start": {
          const hasRegion = regionFrom(params) || num(params, "displayIndex") !== undefined || num(params, "wid") !== undefined || str(params, "app") || str(params, "session");
          const target = hasRegion ? await resolveRegion(params) : undefined;
          return asJson(
            record.start({
              region: target?.output ? undefined : target?.region,
              output: target?.output,
              fps: num(params, "fps"),
              format: params.format === "mov" ? "mov" : "mp4",
            })
          );
        }
        case "pause":
          return asJson(record.setPaused(true));
        case "resume":
          return asJson(record.setPaused(false));
        case "stop":
          return asJson(await record.stop());
        case "status":
          return asJson(record.status());
        default:
          throw new RouterError("capture.record needs action: start, pause, resume, stop or status");
      }
    },
  });

  router.register({
    method: "files.read",
    description: "Read a capture or recording this host wrote (only under ~/.lattices/captures), in base64 chunks",
    access: "read",
    capability: "capture.still",
    params: [
      { name: "path", type: "string", required: true, description: "Path returned by a capture or recording" },
      { name: "offset", type: "int", description: "Byte offset (default 0)" },
      { name: "length", type: "int", description: "Max bytes (default and cap 16 MiB)" },
    ],
    returns: "Object with data (base64), offset, length, size, eof",
    handler: (params) => {
      const requested = requireStr(params, "path");
      let real: string;
      try {
        real = realpathSync(requested);
      } catch {
        throw RouterError.notFound(requested);
      }
      mkdirSync(capture.CAPTURE_DIR, { recursive: true });
      const root = realpathSync(capture.CAPTURE_DIR);
      if (!real.startsWith(root + sep)) throw new RouterError(`files.read only serves files under ${capture.CAPTURE_DIR}`);
      const size = statSync(real).size;
      const offset = Math.max(0, Math.floor(num(params, "offset") ?? 0));
      const length = Math.min(16 * 1024 * 1024, Math.max(0, Math.floor(num(params, "length") ?? 16 * 1024 * 1024)), Math.max(0, size - offset));
      const buffer = Buffer.alloc(length);
      const fd = openSync(real, "r");
      try {
        readSync(fd, buffer, 0, length, offset);
      } finally {
        closeSync(fd);
      }
      return asJson({ data: buffer.toString("base64"), offset, length, size, eof: offset + length >= size });
    },
  });
  return { virtualSpace: registerVirtualSpaceEndpoints(router, ctx.emit) };
}
