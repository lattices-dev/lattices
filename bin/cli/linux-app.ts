import { execFileSync, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function openLinuxApp(page = "Home", viewer?: string): void {
  const main = fileURLToPath(new URL("../../apps/linux/main.ts", import.meta.url));
  if (!existsSync(main)) throw new Error("The Linux app needs a Lattices source checkout containing apps/linux.");
  const bun = process.versions.bun ? process.execPath : "bun";
  execFileSync(bun, [main, "--detach", ...(viewer ? ["--viewer", viewer] : ["--page", page])], { stdio: "inherit" });
}

export function linuxAppRunning(): boolean {
  return linuxAppState().running;
}

export function linuxAppState(): { running: boolean; page: string | null; online: boolean | null; viewer?: { visible: boolean; watching: boolean; fresh: boolean } } {
  const path = fileURLToPath(new URL("../../apps/linux/", import.meta.url));
  const result = spawnSync("quickshell", ["ipc", "--path", path, "--any-display", "call", "lattices", "state"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 1500 });
  if (result.status !== 0) return { running: false, page: null, online: null };
  try { const state = JSON.parse(result.stdout); return { running: true, page: state.page ?? null, online: state.online ?? null, ...(state.viewer ? { viewer: state.viewer } : {}) }; }
  catch { return { running: true, page: null, online: null }; }
}

async function quitLinuxApp(): Promise<void> {
  if (!linuxAppRunning()) return;
  const path = fileURLToPath(new URL("../../apps/linux/", import.meta.url));
  execFileSync("quickshell", ["ipc", "--path", path, "--any-display", "call", "lattices", "quit"], { stdio: "inherit", timeout: 3000 });
  for (let attempt = 0; attempt < 20; attempt++) {
    if (!linuxAppRunning()) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error("The Linux app has not confirmed it closed. The host and tray are independent.");
}

export const linuxAppUsage = "lats app [launch|overview|mission|console|hints|status|quit|restart|install]\n  lats app preview [show|hide|toggle] (alias: pip)\n  Preview watches the virtual desktop without focusing the app. Hiding it leaves the session running.\n  overview opens Flight Deck; mission opens Mission Control; console opens Operator Console. status accepts --json. Quit/restart affect only the app window, leaving host and tray services running.";

export async function linuxAppCommand(args: string[]): Promise<void> {
  if (args[0] === "install") {
    const { installLinux, parseOptions, usage } = await import("../../apps/linux/install.ts");
    if (args.slice(1).some(arg => arg === "--help" || arg === "-h")) console.log(usage);
    else await installLinux(parseOptions(args.slice(1)));
    return;
  }
  if (args.includes("--help") || args.includes("-h")) { console.log(linuxAppUsage); return; }
  const sub = args[0] || "launch";
  if (sub === "preview" || sub === "pip") {
    const action = args[1] || "show";
    if (args.length > 2 || !["show", "hide", "toggle"].includes(action)) throw new Error(linuxAppUsage);
    openLinuxApp("Overview", action);
    return;
  }
  if (!["launch", "start", "overview", "mission", "console", "hints", "status", "quit", "stop", "restart"].includes(sub)
    || args.slice(1).some(arg => arg !== "--json") || (args.includes("--json") && sub !== "status")) throw new Error(linuxAppUsage);
  if (sub === "status") {
    const state = linuxAppState();
    if (args.includes("--json")) console.log(JSON.stringify(state, null, 2));
    else console.log(state.running ? `Lattices app running · ${state.page || "page unknown"} · host ${state.online === null ? "unknown" : state.online ? "connected" : "offline"}` : "Lattices app closed. Open it with: lats app");
  } else if (sub === "quit" || sub === "stop") {
    await quitLinuxApp(); console.log("Lattices app closed. Host and tray services keep running.");
  } else if (sub === "restart") {
    const page = linuxAppState().page ?? "Home";
    await quitLinuxApp(); openLinuxApp(page); console.log("Lattices app restarted.");
  } else openLinuxApp(sub === "hints" ? "Hints" : sub === "overview" ? "Overview" : sub === "mission" ? "Mission" : sub === "console" ? "Console" : "Home");
}
