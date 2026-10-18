// A separate process owns the virtual seat. Its input/capture environment never
// reaches the main host or the user's compositor.
import { spawn, type ChildProcess } from "node:child_process";
import { createWriteStream, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { run, runBuffer } from "./exec.ts";
import * as input from "./input.ts";
import { PointerSession, type Button, type Extent } from "./wayland.ts";
import { bool, num, requireStr, str, type Params } from "./router.ts";

import { VirtualRequestQueue } from "./virtual-request-queue.ts";

interface Node { id: number; app_id?: string; name?: string; focused?: boolean; rect: { x: number; y: number; width: number; height: number }; nodes?: Node[]; floating_nodes?: Node[] }
// D-Bus activated services can write to stdout; fd 3 is reserved for RPC.
const protocol = createWriteStream("", { fd: 3, autoClose: false });
const emit = (value: unknown) => protocol.write(JSON.stringify(value) + "\n");
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

export async function runVirtualSpaceWorker() {
  const directory = process.env.LATTICES_VIRTUAL_RUNTIME;
  if (!directory) throw new Error("Missing private virtual runtime");
  const width = Number(process.env.LATTICES_VIRTUAL_WIDTH ?? 1280);
  const height = Number(process.env.LATTICES_VIRTUAL_HEIGHT ?? 800);
  const extent: Extent = { x: 0, y: 0, w: width, h: height };
  const sway = process.env.LATTICES_VIRTUAL_SWAY ?? "sway";
  const swaymsg = process.env.LATTICES_VIRTUAL_SWAY ? join(dirname(sway), "swaymsg") : "swaymsg";
  // Explicitly remove physical session endpoints before spawning any process.
  for (const key of ["WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "SWAYSOCK", "XDG_SESSION_ID", "SESSION_MANAGER", "LD_LIBRARY_PATH"]) delete process.env[key];
  process.env.XDG_RUNTIME_DIR = directory;
  process.env.XDG_SESSION_TYPE = "wayland";
  process.env.GDK_BACKEND = "wayland";
  process.env.QT_QPA_PLATFORM = "wayland";
  const compositorEnv = { ...process.env, WLR_BACKENDS: "headless", WLR_RENDERER: "pixman", WLR_HEADLESS_OUTPUTS: "1", WLR_LIBINPUT_NO_DEVICES: "1", ...(process.env.LATTICES_VIRTUAL_LIBRARY_PATH ? { LD_LIBRARY_PATH: process.env.LATTICES_VIRTUAL_LIBRARY_PATH } : {}) };
  const apps = new Set<ChildProcess>();
  let compositor: ChildProcess | undefined;
  let pointer: PointerSession | undefined;
  let closing = false;
  let requests: VirtualRequestQueue | undefined;
  let log = "";
  let socket = "";
  let lastInputAt = 0;
  const append = (data: Buffer) => { log = (log + data.toString()).slice(-6000); };
  async function stop() {
    if (closing) return;
    closing = true;
    requests?.stop();
    await pointer?.close().catch(() => {});
    for (const app of apps) { try { if (app.pid) process.kill(-app.pid, "SIGTERM"); } catch {} }
    if (compositor?.exitCode === null) compositor.kill("SIGTERM");
    await sleep(100);
    for (const app of apps) { try { if (app.pid) process.kill(-app.pid, "SIGKILL"); } catch {} }
    if (compositor?.exitCode === null) compositor.kill("SIGKILL");
  }
  let quitting: Promise<void> | undefined;
  const quit = () => quitting ??= (async () => { await stop(); process.exit(0); })();
  protocol.on("error", quit);
  process.on("SIGTERM", quit);
  process.on("SIGINT", quit);
  const lines = createInterface({ input: process.stdin });
  lines.on("close", quit);
  try {
    const config = join(directory, "config");
    writeFileSync(config, `xwayland disable\noutput HEADLESS-1 mode ${width}x${height}\ndefault_border none\nseat seat0 hide_cursor 1500\n`, { mode: 0o600 });
    compositor = spawn(sway, ["--config", config, "--unsupported-gpu"], { env: compositorEnv, stdio: ["ignore", "ignore", "pipe"] });
    compositor.on("spawn", () => emit({ event: "owned-group", pid: compositor!.pid }));
    compositor.stderr?.on("data", append);
    let startupError: Error | undefined;
    compositor.on("error", error => { startupError = error; });
    compositor.on("exit", (code, signal) => {
      if (!closing) { emit({ event: "failed", message: `Virtual desktop stopped (${signal ?? code}). ${log.trim()}` }); void quit(); }
    });
    const ipc = async (type: string, command?: string) => JSON.parse(await run(swaymsg, ["--socket", socket, "--raw", "--type", type, ...(command ? [command] : [])], { env: compositorEnv }));
    let ready = false;
    for (let i = 0; i < 80; i++) {
      if (startupError) throw startupError;
      if (compositor.exitCode !== null) throw new Error(log.trim() || "The virtual compositor exited");
      const files = readdirSync(directory);
      const display = files.find(name => /^wayland-\d+$/.test(name));
      const found = files.find(name => name.startsWith("sway-ipc.") && name.endsWith(".sock"));
      if (display && found) {
        socket = join(directory, found);
        const outputs = await ipc("get_outputs").catch(() => []);
        if (outputs.length === 1 && outputs[0].name === "HEADLESS-1" && outputs[0].active) {
          process.env.WAYLAND_DISPLAY = display;
          process.env.SWAYSOCK = socket;
          ready = true; break;
        }
      }
      await sleep(100);
    }
    if (!ready) throw new Error("Headless desktop did not become ready. " + log.trim());
    // Update only the fresh private bus, after its virtual display is ready.
    await run("dbus-update-activation-environment", ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "XDG_SESSION_TYPE"]);
    pointer = await PointerSession.open();
    await pointer.move(width / 2, height / 2, extent);
    async function windows() {
      const tree = await ipc("get_tree") as Node;
      const result: { wid: number; app: string; title: string; isFocused: boolean; frame: { x: number; y: number; w: number; h: number } }[] = [];
      function visit(node: Node) {
        if (node.app_id) result.push({ wid: node.id, app: node.app_id, title: node.name ?? "", isFocused: !!node.focused, frame: { x: node.rect.x, y: node.rect.y, w: node.rect.width, h: node.rect.height } });
        for (const child of [...(node.nodes ?? []), ...(node.floating_nodes ?? [])]) visit(child);
      }
      visit(tree); return result;
    }
    async function target(params: Params) {
      const all = await windows();
      const wid = num(params, "wid");
      const app = str(params, "app")?.toLowerCase();
      const title = str(params, "title")?.toLowerCase();
      const selected = wid !== undefined ? all.find(w => w.wid === wid) : app ? all.find(w => w.app.toLowerCase().includes(app) && (!title || w.title.toLowerCase().includes(title))) : all.find(w => w.isFocused);
      if ((wid !== undefined || app) && !selected) throw new Error("No matching window in the virtual space");
      return selected;
    }
    const point = async (params: Params) => {
      const window = num(params, "wid") !== undefined || str(params, "app") ? await target(params) : undefined;
      const xr = num(params, "xRatio"), yr = num(params, "yRatio");
      const frame = window?.frame ?? extent;
      const x = num(params, "x") ?? (xr === undefined ? undefined : frame.x + xr * frame.w);
      const y = num(params, "y") ?? (yr === undefined ? undefined : frame.y + yr * frame.h);
      if (x === undefined || y === undefined || x < 0 || y < 0 || x >= width || y >= height) throw new Error("A point inside the virtual space is required");
      return { x, y };
    };
    async function focus(params: Params) {
      const window = await target(params);
      if (!window) throw new Error("No focused window in the virtual space");
      const result = await ipc("command", `[con_id=${window.wid}] focus`);
      if (result.some((r: { success: boolean }) => !r.success)) throw new Error("Could not focus the virtual window");
      return window;
    }
    const capture = async () => {
      // Input is acknowledged before clients commit their next rendered frame.
      const settle = 150 - (Date.now() - lastInputAt);
      if (settle > 0) await sleep(settle);
      const bytes = await runBuffer("grim", ["-t", "png", "-"], 5000);
      return { space: "virtual", width, height, format: "png", image: bytes.toString("base64"), updatedAt: Date.now() };
    };
    async function perform(method: string, params: Params) {
      if (method === "status") return { running: true, space: "virtual", width, height, windows: await windows() };
      if (method === "capture") return capture();
      if (method === "launch") {
        const app = requireStr(params, "app");
        const args = Array.isArray(params.args) ? params.args.map(String) : [];
        const executable = Bun.which(app);
        if (!executable) throw new Error(`Missing application: ${app}`);
        const child = spawn(executable, args, { env: process.env, detached: true, stdio: ["ignore", "ignore", "pipe"] });
        await new Promise<void>((resolve, reject) => { child.once("spawn", resolve); child.once("error", reject); });
        emit({ event: "owned-group", pid: child.pid });
        apps.add(child); child.stderr?.on("data", append);
        child.once("exit", () => {
          // Finish any descendants while this launch's process group is ours.
          try { if (child.pid) process.kill(-child.pid, "SIGTERM"); } catch {}
          apps.delete(child);
        });
        return { ok: true, space: "virtual", pid: child.pid };
      }
      if (method === "computer.observe") {
        const shot = await capture();
        const text = await run("tesseract", ["stdin", "stdout", "--psm", "3"], { input: Buffer.from(shot.image, "base64"), timeoutMs: 30000 });
        return { ok: true, space: "virtual", region: extent, text: text.trim(), window: await target(params) ?? null, ...(bool(params, "image") ? { image: shot.image } : {}) };
      }
      const execute = params.treatment === "execute" && params.dryRun !== true;
      let plan: Record<string, unknown>;
      let act: () => Promise<unknown>;
      if (["computer.click", "computer.doubleClick", "computer.rightClick", "computer.aim"].includes(method)) {
        const p = await point(params);
        const button = method === "computer.rightClick" ? "right" : str(params, "button") ?? "left";
        if (!["left", "right", "middle"].includes(button)) throw new Error("Invalid pointer button");
        const count = method === "computer.doubleClick" ? 2 : num(params, "count") ?? 1;
        if (!Number.isInteger(count) || count < 1 || count > 8) throw new Error("Click count must be from 1 to 8");
        plan = { point: p, button, count };
        act = async () => {
          await pointer!.move(p.x, p.y, extent);
          if (method !== "computer.aim") for (let i = 0; i < count; i++) {
            if (i) await sleep(80);
            await pointer!.button(button as Button, true);
            await pointer!.button(button as Button, false);
          }
        };
      } else if (method === "computer.scroll") {
        const p = params.x !== undefined || params.xRatio !== undefined ? await point(params) : undefined;
        const dx = num(params, "dx") ?? 0, dy = num(params, "dy") ?? 0;
        plan = { point: p ?? null, dx, dy }; act = async () => { if (p) await pointer!.move(p.x, p.y, extent); await pointer!.scroll(dx * 15, dy * 15); };
      } else if (method === "computer.drag") {
        const from = await point({ x: params.fromX, y: params.fromY }), to = await point({ x: params.toX, y: params.toY });
        plan = { from, to }; act = async () => {
          await pointer!.move(from.x, from.y, extent); await pointer!.button("left", true);
          try { for (let i = 1; i <= 12; i++) { await pointer!.move(from.x + (to.x - from.x) * i / 12, from.y + (to.y - from.y) * i / 12, extent); await sleep(10); } }
          finally { await pointer!.button("left", false); }
        };
      } else if (method === "computer.typeText") {
        if (params.session !== undefined) throw new Error("Virtual input cannot target a host tmux session");
        const text = typeof params.text === "string" ? params.text : undefined;
        if (text === undefined) throw new Error("Text is required");
        const enter = bool(params, "enter") ?? false;
        plan = { length: text.length, enter }; act = async () => { await focus(params); if (text) await run("wtype", ["-s", "100", "--", text]); if (enter) await run("wtype", ["-s", "100", "-k", "Return"]); };
      } else if (method === "computer.pressKey" || method === "computer.hotkey") {
        const shortcut = str(params, "shortcut");
        const parsed = shortcut ? input.parseShortcut(shortcut) : { key: requireStr(params, "key"), modifiers: [] };
        const modifiers = [...parsed.modifiers, ...(Array.isArray(params.modifiers) ? params.modifiers.map(String) : typeof params.modifiers === "string" ? params.modifiers.split(/[+, ]+/).filter(Boolean) : [])];
        const count = num(params, "count") ?? 1;
        if (!Number.isInteger(count) || count < 1 || count > 20) throw new Error("Key count must be from 1 to 20");
        input.wtypeKeyArgs(parsed.key, modifiers, count);
        plan = { key: parsed.key, modifiers, count }; act = async () => { await focus(params); await run("wtype", ["-s", "100", ...input.wtypeKeyArgs(parsed.key, modifiers, count)]); };
      } else throw new Error(`Unsupported virtual action: ${method}`);
      if (execute) { await act(); lastInputAt = Date.now(); }
      return { ok: true, space: "virtual", executed: execute, status: execute ? "executed" : "staged", ...plan };
    }
    emit({ event: "ready", width, height });
    requests = new VirtualRequestQueue(perform, emit);
    lines.on("line", line => {
      try {
        const request = JSON.parse(line);
        if (request.cancel !== undefined) requests!.cancel(request.cancel);
        else void requests!.enqueue(request);
      } catch (error) { emit({ error: (error as Error).message }); }
    });
  } catch (error) { emit({ event: "failed", message: (error as Error).message }); await stop(); process.exit(1); }
}
