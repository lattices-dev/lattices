import { currentRequestContext, assertRequestActive } from "./request-context.ts";
import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { homedir, tmpdir } from "node:os";
import { existsSync, mkdirSync, mkdtempSync, rmSync, readdirSync, readFileSync } from "node:fs";
import type { Readable } from "node:stream";
import { join } from "node:path";
import { Router, num, str, type Json, type Params } from "./router.ts";

const json = (value: unknown) => value as Json;
export class VirtualSpace {
  private child: ChildProcess | null = null;
  private ready: Promise<void> | undefined;
  private cleanup: Promise<void> | undefined;
  private pending = new Map<number, { resolve: (result: unknown) => void; reject: (error: Error) => void; started?: boolean; timer: ReturnType<typeof setTimeout> }>();
  private nextId = 0;
  private width = 1280;
  private height = 800;
  private error: string | null = null;
  private closing = false;
  constructor(private emit: (event: string, data: unknown) => void = () => {}, private options: {
    runtimeRoot?: string; workerArgs?: string[]; available?: () => { available: boolean; reason: string | null };
    requestTimeoutMs?: number; startupTimeoutMs?: number;
  } = {}) {}
  private availability() {
    if (this.options.available) return this.options.available();
    const sway = process.env.LATTICES_VIRTUAL_SWAY;
    const missing = ["dbus-run-session", "dbus-update-activation-environment", "grim", "wtype"].filter(name => !Bun.which(name));
    if (!(sway ? existsSync(sway) : Bun.which("sway"))) missing.push("sway");
    return { available: missing.length === 0, reason: missing.length ? "Install " + missing.join(", ") + " to use virtual space" : null };
  }
  async status() {
    return { ...this.availability(), space: "virtual", running: !!this.child && !this.closing, width: this.width, height: this.height, error: this.error, ...(this.child && this.ready && !this.closing ? await this.request("status") as object : { windows: [] }) };
  }
  async start(params: Params) {
    if (this.closing) throw new Error("Virtual space is stopping");
    await this.cleanup;
    if (this.closing) throw new Error("Virtual space is stopping");
    if (this.child) { await this.ready; return this.status(); }
    const availability = this.availability();
    if (!availability.available) throw new Error(availability.reason!);
    const width = num(params, "width") ?? 1280, height = num(params, "height") ?? 800;
    if (!Number.isInteger(width) || !Number.isInteger(height) || width < 640 || width > 2560 || height < 480 || height > 1600) throw new Error("Virtual space size must be from 640×480 to 2560×1600");
    this.width = width; this.height = height; this.error = null; this.closing = false;
    const directory = mkdtempSync(join(this.options.runtimeRoot ?? tmpdir(), "lattices-virtual-"));
    const env = { ...process.env, LATTICES_VIRTUAL_RUNTIME: directory, LATTICES_VIRTUAL_WIDTH: String(width), LATTICES_VIRTUAL_HEIGHT: String(height), XDG_CURRENT_DESKTOP: "sway", XDG_SESSION_DESKTOP: "sway" } as NodeJS.ProcessEnv;
    // The private D-Bus daemon must never inherit physical display endpoints.
    for (const key of ["WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "SWAYSOCK", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "DBUS_STARTER_ADDRESS", "DBUS_STARTER_BUS_TYPE", "AT_SPI_BUS_ADDRESS", "XDG_SESSION_ID", "SESSION_MANAGER", "LD_LIBRARY_PATH"]) delete env[key];
    env.XDG_RUNTIME_DIR = directory;
    const child = spawn("dbus-run-session", ["--", process.execPath, ...(this.options.workerArgs ?? [process.argv[1], "__virtual-space-worker"])], { env, detached: true, stdio: ["pipe", "ignore", "pipe", "pipe"] });
    this.child = child;
    const groups = new Set<number>(child.pid ? [child.pid] : []);
    const identities = new Map<number, string>();
    const remember = (pid: number) => {
      try {
        const stat = readFileSync("/proc/" + pid + "/stat", "utf8");
        const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
        identities.set(pid, fields[19]);
        groups.add(Number(fields[2]));
      } catch {}
    };
    if (child.pid) remember(child.pid);
    let stderr = "";
    child.stderr?.on("data", data => { stderr = (stderr + String(data)).slice(-4000); });
    this.ready = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { reject(new Error("Virtual desktop startup timed out")); }, this.options.startupTimeoutMs ?? 12000);
      const lines = createInterface({ input: child.stdio[3] as Readable });
      lines.on("line", line => {
        try {
          const message = JSON.parse(line);
          if (message.event === "owned-group") { if (Number.isInteger(message.pid) && message.pid > 1) remember(message.pid); return; }
          if (message.event === "ready") { clearTimeout(timer); if (this.closing) { reject(new Error("Virtual startup cancelled by stop")); return; } resolve(); this.emit("virtual.changed", { running: true }); }
          else if (message.event === "failed") { clearTimeout(timer); this.error = message.message; reject(new Error(message.message)); this.emit("virtual.changed", { running: false, error: message.message }); }
          else {
            const pending = this.pending.get(message.id);
            if (!pending) return;
            if (message.event === "started") { pending.started = true; return; }
            clearTimeout(pending.timer); this.pending.delete(message.id);
            if (message.error) pending.reject(new Error(message.error)); else pending.resolve(message.result);
          }
        } catch { /* Non-protocol output is not a response. */ }
      });
      const failed = (error: Error) => {
        clearTimeout(timer); reject(error);
        if (this.child !== child) return;
        this.child = null; this.ready = undefined;
        if (!this.closing) this.error ??= error.message;
        for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error(pending.started ? error.message + "; action outcome uncertain; do not retry blindly" : error.message + "; worker lost before cancellation confirmation; outcome uncertain")); }
        this.pending.clear(); this.emit("virtual.changed", { running: false, error: this.error });
        // Portals release their runtime mounts after the private bus exits.
        this.cleanup = (async () => {
          // The worker's apps have separate process groups. Keep their ownership
          // until the entire lifecycle ends, including unexpected worker death.
          const members = readdirSync("/proc").filter(name => /^\d+$/.test(name)).flatMap(name => {
            try {
              const stat = readFileSync("/proc/" + name + "/stat", "utf8");
              const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
              if (fields[0] === "Z") return [];
              let owned = identities.get(Number(name)) === fields[19];
              // Sway may make environ unreadable after dropping privileges.
              try { owned ||= readFileSync("/proc/" + name + "/environ", "utf8").split("\0").includes("XDG_RUNTIME_DIR=" + directory); } catch {}
              return [{ group: Number(fields[2]), owned }];
            } catch { return []; }
          });
          // Discover launches even if a crash beat their ownership message.
          for (const member of members) if (member.owned) groups.add(member.group);
          for (const group of groups) {
            const live = members.filter(member => member.group === group);
            if (!live.length) continue;
            if (!live.some(member => member.owned)) throw new Error("Virtual process group identity could not be verified: " + group);
            try { process.kill(-group, "SIGKILL"); }
            catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error; }
          }
          const alive = () => readdirSync("/proc").filter(name => /^\d+$/.test(name)).some(name => {
            try {
              const stat = readFileSync("/proc/" + name + "/stat", "utf8");
              const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
              return fields[0] !== "Z" && groups.has(Number(fields[2]));
            } catch { return false; }
          });
          for (let i = 0; alive(); i++) {
            if (i >= 40) throw new Error("Virtual owned process groups survived cleanup");
            await new Promise(resolve => setTimeout(resolve, 50));
          }
          for (let i = 0; i < 20; i++) {
            try { rmSync(directory, { recursive: true, force: true }); return; }
            catch (error) {
              if (i === 19) throw new Error("Virtual runtime cleanup failed: " + (error as Error).message);
              await new Promise(resolve => setTimeout(resolve, 100));
            }
          }
        })();
        void this.cleanup.catch(error => { this.error = (error as Error).message; });
      };
      child.on("error", failed);
      child.on("exit", () => failed(new Error(stderr.trim() || "Virtual desktop stopped")));
    });
    try { await this.ready; return await this.status(); }
    catch (error) { await this.stop(); throw error; }
  }
  private async request(method: string, params: Params = {}): Promise<unknown> {
    const context = currentRequestContext();
    assertRequestActive(context);
    const mutates = method === "launch" || (method.startsWith("computer.") && method !== "computer.observe" && params.treatment === "execute" && params.dryRun !== true);
    if (context && mutates && context.deadline === undefined) {
      throw new Error("Virtual mutations require an absolute request deadline (Unix milliseconds); on connection loss treat the outcome as uncertain");
    }
    await this.ready;
    assertRequestActive(context);
    const child = this.child;
    if (!child || this.closing) throw new Error("Start the virtual space first");
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timeout = this.options.requestTimeoutMs ?? (method === "computer.observe" ? 35000 : 10000);
      const deadline = Math.min(Date.now() + timeout, context?.deadline ?? Infinity);
      const finishResolve = resolve, finishReject = reject;
      const detach = () => context?.signal?.removeEventListener("abort", cancel);
      resolve = value => { detach(); finishResolve(value); };
      reject = error => { detach(); finishReject(error); };
      let cancelling = false;
      const cancel = () => {
        const pending = this.pending.get(id);
        if (!pending || cancelling) return;
        cancelling = true;
        clearTimeout(pending.timer);
        // The worker acknowledges whether cancellation beat execution.
        pending.timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new Error("Virtual cancellation unconfirmed; action outcome uncertain; do not retry blindly"));
        }, 1000);
        child.stdin!.write(JSON.stringify({ cancel: id }) + "\n", error => {
          if (error) { clearTimeout(pending.timer); this.pending.delete(id); reject(new Error("Virtual connection lost; action outcome uncertain")); }
        });
      };
      const timer = setTimeout(cancel, Math.max(0, deadline - Date.now()));
      this.pending.set(id, { resolve, reject, timer });
      context?.signal?.addEventListener("abort", cancel, { once: true });
      child.stdin!.write(JSON.stringify({ id, method, params, deadline }) + "\n", error => { if (error) { clearTimeout(timer); this.pending.delete(id); reject(new Error("Virtual connection lost; action outcome uncertain; do not retry blindly")); } });
    });
  }
  async perform(method: string, params: Params) {
    if (params.space !== "virtual") throw new Error("Unknown space target; use space: virtual");
    return this.request(method, params);
  }
  capture() { return this.request("capture"); }
  async launch(params: Params) {
    let app = str(params, "app");
    if (app === "terminal") { app = Bun.which("foot") ? "foot" : undefined; params = { app: app ?? "foot", args: ["--title=Lattices virtual terminal"] }; }
    else if (app === "browser") {
      app = ["chromium", "google-chrome", "google-chrome-stable"].find(name => Bun.which(name));
      if (!app) throw new Error("Install Chromium or Chrome to open a virtual browser");
      const profile = join(homedir(), ".lattices", "virtual-space", "browser");
      mkdirSync(profile, { recursive: true, mode: 0o700 });
      params = { app, args: ["--ozone-platform=wayland", "--disable-gpu", "--no-first-run", "--no-default-browser-check", `--user-data-dir=${profile}`, "about:blank"] };
    }
    if (!app) throw new Error("An application is required");
    const result = await this.request("launch", params);
    this.emit("virtual.changed", { running: true });
    return result;
  }
  async stop() {
    const child = this.child;
    if (!child) { await this.cleanup; return { ok: true, running: false }; }
    this.closing = true;
    // EOF lets the worker terminate its own app groups and compositor cleanly.
    child.stdin?.end();
    await new Promise<void>((resolve, reject) => {
      let finalTimer: ReturnType<typeof setTimeout> | undefined;
      const timer = setTimeout(() => {
        try { if (child.pid) process.kill(-child.pid, "SIGKILL"); }
        catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") { reject(error); return; } }
        finalTimer = setTimeout(() => reject(new Error("Virtual worker did not exit after SIGKILL")), 2000);
      }, 4000);
      child.once("exit", () => { clearTimeout(timer); clearTimeout(finalTimer); resolve(); });
    });
    await this.cleanup;
    if (this.child === child) this.child = null;
    this.ready = undefined; this.closing = false;
    this.emit("virtual.changed", { running: false });
    return { ok: true, running: false };
  }
}

export function registerVirtualSpaceEndpoints(router: Router, emit?: (event: string, data: unknown) => void) {
  const virtual = new VirtualSpace(emit);
  const actions = ["computer.click", "computer.doubleClick", "computer.rightClick", "computer.aim", "computer.scroll", "computer.drag", "computer.typeText", "computer.pressKey", "computer.hotkey", "computer.observe"];
  for (const method of actions) {
    const physical = router.lookup(method)!;
    router.register({ ...physical, params: [...(physical.params ?? []), { name: "space", type: "string", description: "virtual targets the isolated desktop; omit for the physical desktop" }], handler: params => params.space === undefined ? physical.handler(params) : virtual.perform(method, params).then(json) });
  }
  for (const [name, access, handler] of [
    ["status", "read", () => virtual.status()], ["start", "mutate", (p: Params) => virtual.start(p)], ["stop", "mutate", () => virtual.stop()], ["launch", "mutate", (p: Params) => virtual.launch(p)], ["capture", "read", () => virtual.capture()],
  ] as const) router.register({ method: "computer.virtual." + name, access, description: `Isolated virtual desktop: ${name}`, params: [{ name: "app", type: "string", description: "browser, terminal or executable name (launch)" }, { name: "args", type: "array", description: "Executable arguments (launch)" }, { name: "width", type: "int", description: "Virtual width (start, default 1280)" }, { name: "height", type: "int", description: "Virtual height (start, default 800)" }], returns: "Virtual desktop state, screenshot or action receipt", handler: params => handler(params).then(json) });
  return virtual;
}
