import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

if (process.platform !== "linux") throw new Error("The Linux app needs a Linux desktop.");
const quickshell = Bun.which("quickshell");
if (!quickshell) throw new Error("Install Quickshell to run the Linux app.");
const args = process.argv.slice(2);
const pageIndex = args.indexOf("--page");
const page = pageIndex === -1 ? "Home" : args[pageIndex + 1];
if (!page || !["Home", "Overview", "Layers", "Activity", "Settings", "Hints", "Mission", "Console"].includes(page)) throw new Error("Unknown Linux app page");
const viewerIndex = args.indexOf("--viewer");
const viewer = viewerIndex === -1 ? undefined : args[viewerIndex + 1];
if (viewerIndex !== -1 && !["show", "hide", "toggle"].includes(viewer || "")) throw new Error("Viewer action must be show, hide or toggle");
const path = fileURLToPath(new URL("./", import.meta.url));
// Quickshell reserves `show` in its CLI parser, even in argument position.
const viewerArgument = viewer === "show" ? "on" : viewer === "hide" ? "off" : viewer;
const existing = spawnSync(quickshell, ["ipc", "--path", path, "--any-display", "call", "lattices", ...(viewer ? ["viewer", viewerArgument!] : ["showPage", page])], { stdio: "ignore", timeout: 3000 });
if (existing.status === 0) process.exit(0);
if (viewer === "hide") process.exit(0);
const child = spawn(quickshell, ["--path", path, "--no-duplicate", ...(args.includes("--detach") ? ["--daemonize"] : [])], {
  stdio: "inherit",
  env: { ...process.env, LATTICES_LINUX_BUN: process.execPath, LATTICES_LINUX_PAGE: page, LATTICES_LINUX_VIEWER: viewer ? "show" : "" },
});
process.on("SIGINT", () => child.kill("SIGINT"));
process.on("SIGTERM", () => child.kill("SIGTERM"));
child.on("error", (error) => { console.error(error.message); process.exitCode = 1; });
child.on("exit", (code) => { process.exitCode = code ?? 0; });
