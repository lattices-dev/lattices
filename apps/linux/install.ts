import { createHash, randomUUID } from "node:crypto";
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export interface InstallOptions { gestures: boolean; wheel: boolean; start: boolean; dryRun: boolean; replace: boolean }
export const usage = `Install Lattices for Linux (Hyprland + Quickshell)

  bun run linux:install [options]

  --gestures          Forward-button gestures and the pen trail (Omarchy only)
  --wheel-gestures    Also reserve plain wheel-click for gestures; implies --gestures
  --no-start          Install files without starting services or opening the app
  --dry-run           Show the plan without writing files or starting anything
  --replace-existing Back up and replace files owned by an older/manual install
  --no-deps           Bootstrap only: skip system packages (JS dependencies still install)
  --help              Show this help

Run inside your Hyprland desktop to start and verify the host and tray.
Use --no-start when preparing an installation over SSH or outside the desktop.`;

export function parseOptions(args: string[]): InstallOptions {
  const options = { gestures: false, wheel: false, start: true, dryRun: false, replace: false };
  for (const arg of args) {
    if (arg === "--gestures") options.gestures = true;
    else if (arg === "--wheel-gestures") { options.gestures = true; options.wheel = true; }
    else if (arg === "--no-start") options.start = false;
    else if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--replace-existing") options.replace = true;
    else if (arg !== "--no-deps") throw new Error(`Unknown option: ${arg}\n${usage}`);
  }
  return options;
}

export const shellQuote = (text: string) => "'" + text.replaceAll("'", "'\\''") + "'";
export function unitQuote(text: string, expandVariables = true): string {
  if (/[\x00-\x1f\x7f]/.test(text)) throw new Error("Invalid service argument");
  const escaped = text.replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("%", "%%");
  return '"' + (expandVariables ? escaped.replaceAll("$", () => "$$") : escaped) + '"';
}
export function desktopQuote(text: string): string {
  validPath(text);
  if (text.includes("=")) throw new Error("The desktop launcher path cannot contain '='.");
  return '"' + text.replace(/[\\"`$]/g, char => "\\" + char).replaceAll("\\", "\\\\").replaceAll("%", "%%") + '"';
}
function validPath(path: string) {
  if (!isAbsolute(path) || /[\x00-\x1f\x7f]/.test(path)) throw new Error(`Expected an absolute path without control characters: ${JSON.stringify(path)}`);
}
const hash = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
const present = (path: string) => { try { lstatSync(path); return true; } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; return false; } };

export interface InstallPaths { home: string; bin: string; data: string; config: string; state: string; runtime: string; receipt: string }
export function installPaths(env: NodeJS.ProcessEnv = process.env): InstallPaths {
  const home = env.HOME || homedir();
  const data = env.XDG_DATA_HOME || join(home, ".local/share");
  const config = env.XDG_CONFIG_HOME || join(home, ".config");
  const state = env.XDG_STATE_HOME || join(home, ".local/state");
  const bin = join(home, ".local/bin"), runtime = join(data, "lattices/linux-runtime");
  for (const value of [home, data, config, state, bin]) validPath(value);
  return { home, data, config, state, bin, runtime, receipt: join(runtime, "install.json") };
}
export interface CommandResult { status: number; stdout: string; stderr: string }
export type Runner = (command: string, args: string[], timeout?: number) => CommandResult;
const defaultRun: Runner = (command, args, timeout = 120000) => {
  const result = Bun.spawnSync([command, ...args], { stdout: "pipe", stderr: "pipe", timeout, env: { ...process.env, BUN_INSTALL_AUTO: "disable" } });
  return { status: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString() };
};
interface Receipt { schema: 1; release: string; files: Record<string, string>; backup: string; gestures: boolean; wheel: boolean; appReleases?: string[] }
interface PlannedFile { path: string; content: string; mode: number; shared?: boolean }
interface InstallContext { source?: string; paths?: InstallPaths; run?: Runner; which?: (command: string) => string | null; bun?: string; log?: (message: string) => void; omarchy?: string }
const payload = ["bin", "apps/linux", "packages/host-linux/src", "packages/host-linux/visitor", "packages/host-linux/package.json", "packages/host-linux/bun.lock", "packages/npm/sdk", "assets/logo-mark.svg", "package.json", "docs"];
const excluded = new Set(["node_modules", ".systemd", "test", "tests", ".git"]);
function walk(path: string, prefix = ""): string[] {
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) throw new Error(`Runtime source contains a symlink: ${path}`);
  if (stat.isFile()) return [prefix];
  return readdirSync(path).sort().filter(name => !excluded.has(name)).flatMap(name => walk(join(path, name), join(prefix, name)));
}
export function runtimeFiles(source: string): string[] {
  return payload.flatMap(item => {
    if (!existsSync(join(source, item))) throw new Error(`Linux runtime source is missing ${item}`);
    return walk(join(source, item), item);
  });
}
export function mergeBindings(text: string): string {
  const block = '-- BEGIN LATTICES GESTURES\nrequire("hypr.lattices-mouse")\n-- END LATTICES GESTURES';
  const marked = /-- BEGIN LATTICES GESTURES\n[\s\S]*?-- END LATTICES GESTURES/g;
  if (marked.test(text)) return text.replace(marked, block);
  if (/require\s*\(?\s*["']hypr\.lattices-mouse["']/.test(text)) return text;
  if (/o\.bind\(\s*["']SUPER\s*\+\s*CTRL\s*\+\s*G["']/.test(text)) throw new Error("Super+Ctrl+G is already configured. Free that binding before installing gesture testing.");
  return text.replace(/\s*$/, "") + "\n\n" + block + "\n";
}
export function mergeShell(text: string): string {
  const config = text ? JSON.parse(text) : {};
  if (!config || Array.isArray(config) || typeof config !== "object" || (config.plugins !== undefined && !Array.isArray(config.plugins))) throw new Error("Omarchy shell.json must be an object with a plugins array.");
  const plugins = config.plugins ?? [];
  if (plugins.some((entry: unknown) => entry === "lattices.gestures" || (entry && typeof entry === "object" && (entry as { id?: unknown }).id === "lattices.gestures"))) return text;
  config.plugins = [...plugins, { id: "lattices.gestures" }];
  return JSON.stringify(config, null, 2) + "\n";
}

export async function installLinux(options: InstallOptions, context: InstallContext = {}) {
  if (process.platform !== "linux") throw new Error("This installer needs Linux.");
  if (process.getuid?.() === 0 && !context.paths) throw new Error("Run the installer as your desktop user, without sudo.");
  const source = resolve(context.source ?? fileURLToPath(new URL("../../", import.meta.url)));
  const paths = context.paths ?? installPaths();
  const which = context.which ?? Bun.which;
  const run = context.run ?? defaultRun, log = context.log ?? console.log;
  const bun = context.bun ?? process.execPath;
  const checked = (command: string, args: string[], timeout?: number) => {
    const result = run(command, args, timeout);
    if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} failed: ${(result.stderr || result.stdout).trim()}`);
    return result;
  };
  let previous: Receipt | null = null;
  if (present(paths.receipt)) {
    previous = JSON.parse(readFileSync(paths.receipt, "utf8"));
    if (previous?.schema !== 1 || typeof previous.files !== "object") throw new Error("Unrecognized Linux install receipt; existing files were left intact.");
  }
  // An update without gesture flags retains the explicitly chosen profile.
  if (previous?.gestures && !options.gestures) options = { ...options, gestures: true, wheel: previous.wheel };
  for (const command of ["hyprctl", "quickshell", "tmux", "systemctl", ...(options.gestures ? ["python3", "Hyprland"] : [])]) {
    if (!which(command)) throw new Error(`Missing ${command}. Run bash install.sh to install dependencies, or install it with your distribution's package manager.`);
  }
  if (options.start && !options.dryRun) {
    checked("hyprctl", ["-j", "monitors"], 5000);
    checked("systemctl", ["--user", "show-environment"], 5000);
  }
  const files = runtimeFiles(source);
  const digest = createHash("sha256");
  for (const file of files) digest.update(file).update("\0").update(readFileSync(join(source, file)));
  const releaseId = digest.digest("hex").slice(0, 20);
  const release = join(paths.runtime, "releases", releaseId), current = join(paths.runtime, "current");
  const launcher = join(paths.bin, "lats");
  const planned: PlannedFile[] = [];
  const add = (path: string, content: string, mode = 0o644, shared = false) => {
    if (shared && present(path) && !lstatSync(path).isSymbolicLink()) mode = lstatSync(path).mode & 0o777;
    planned.push({ path, content, mode, shared });
  };
  const wrapper = (entry: string, trailing = "") => `#!/bin/sh\n# Lattices managed Linux install\nexec ${shellQuote(bun)} ${shellQuote(join(current, entry))}${trailing} "$@"\n`;
  add(launcher, wrapper("bin/lattices.ts"), 0o755);
  add(join(paths.bin, "lattices"), wrapper("bin/lattices.ts"), 0o755);
  add(join(paths.bin, "lattices-host"), wrapper("packages/host-linux/src/main.ts"), 0o755);
  const desktop = readFileSync(join(source, "apps/linux/lattices.desktop"), "utf8").replace(/^Exec=lats(.*)$/gm, (_, args: string) => `Exec=${desktopQuote(launcher)}${args}`);
  add(join(paths.data, "applications/org.lattices.Lattices.desktop"), desktop);
  add(join(paths.data, "icons/hicolor/scalable/apps/lattices.svg"), readFileSync(join(source, "assets/logo-mark.svg"), "utf8"));
  const environmentPath = [...new Set([paths.bin, dirname(bun), ...(process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin").split(":").filter(isAbsolute)])].join(":");
  for (const name of ["host", "tray"]) {
    add(join(paths.config, `systemd/user/lattices-${name}.service`), `[Unit]\nDescription=Lattices ${name}\nPartOf=graphical-session.target\nAfter=graphical-session.target\n\n[Service]\nExecStart=${unitQuote(bun)} ${unitQuote(join(current, "packages/host-linux/src/main.ts"))} ${name === "tray" ? "tray" : "--quiet"}\nEnvironment=${unitQuote("PATH=" + environmentPath, false)}\nRestart=on-failure\nRestartSec=3\n\n[Install]\nWantedBy=graphical-session.target\n`);
  }
  let gestureRelease: string | null = null;
  if (options.gestures) {
    const omarchy = context.omarchy ?? process.env.OMARCHY_PATH ?? "/usr/share/omarchy";
    const mainConfig = join(paths.config, "hypr/hyprland.lua");
    if (!options.dryRun) {
      const version = checked("Hyprland", ["--version"], 5000).stdout.match(/Hyprland\s+v?(\d+)\.(\d+)/i);
      if (!version || (Number(version[1]) === 0 && Number(version[2]) < 56)) throw new Error("Omarchy gestures require Hyprland 0.56 or later.");
    }
    if (!existsSync(join(omarchy, "default/hypr/helpers.lua")) || !existsSync(mainConfig)) throw new Error("Gesture setup needs Omarchy's Lua Hyprland configuration. Core Lattices can install without --gestures.");
    const buttons = options.wheel ? '{ "mouse:276", "mouse:277", "mouse:274" }' : '{ "mouse:276", "mouse:277" }';
    const module = readFileSync(join(source, "apps/linux/omarchy/lattices-mouse.lua.in"), "utf8")
      .replace("@LATS@", JSON.stringify(launcher)).replace("@SPACE_HELPER@", JSON.stringify(join(paths.bin, "lattices-gesture-space")))
      .replace("@FAB@", JSON.stringify(which("fab-linux") ?? join(paths.bin, "fab-linux"))).replace("@BUTTONS@", buttons);
    add(join(paths.config, "hypr/lattices-mouse.lua"), module);
    const helper = readFileSync(join(source, "apps/linux/omarchy/lattices-gesture-space.py.in"), "utf8").replace("@LATS_PYTHON@", JSON.stringify(launcher));
    add(join(paths.bin, "lattices-gesture-space"), helper, 0o755);
    const bindings = join(paths.config, "hypr/bindings.lua"), shell = join(paths.config, "omarchy/shell.json");
    add(bindings, mergeBindings(existsSync(bindings) ? readFileSync(bindings, "utf8") : ""), 0o644, true);
    add(shell, mergeShell(existsSync(shell) ? readFileSync(shell, "utf8") : ""), 0o644, true);
    const pluginSource = join(source, "apps/linux/omarchy/plugin"), pluginRoot = join(paths.config, "omarchy/plugins/lattices.gestures");
    const pluginFiles = walk(pluginSource).filter(path => path !== "manifest.json");
    const pluginHash = createHash("sha256");
    for (const file of pluginFiles) pluginHash.update(file).update(readFileSync(join(pluginSource, file)));
    const version = pluginHash.digest("hex").slice(0, 16);
    gestureRelease = join(pluginRoot, "releases", version);
    // Immutable component directories avoid Qt's stale QML and directory caches.
    for (const file of pluginFiles) add(join(gestureRelease, file), readFileSync(join(pluginSource, file), "utf8"));
    const manifest = JSON.parse(readFileSync(join(pluginSource, "manifest.json"), "utf8"));
    manifest.entryPoints.service = `releases/${version}/${manifest.entryPoints.service}`;
    add(join(pluginRoot, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  }
  const conflicts: string[] = [];
  for (const file of planned) {
    if (!present(file.path)) continue;
    const stat = lstatSync(file.path);
    if (stat.isSymbolicLink() && file.shared) throw new Error(`Config file is a symlink: ${file.path}. Keep it intact and add the documented gesture include manually.`);
    if (stat.isDirectory()) throw new Error(`Expected a file: ${file.path}`);
    const unchanged = !stat.isSymbolicLink() && hash(readFileSync(file.path)) === hash(file.content);
    const owned = !stat.isSymbolicLink() && previous?.files[file.path] === hash(readFileSync(file.path));
    if (!unchanged && !file.shared && !owned && !options.replace) conflicts.push(file.path);
  }
  if (present(current) && (!previous || !lstatSync(current).isSymbolicLink())) conflicts.push(current);
  if (conflicts.length) throw new Error(`Existing files need review:\n${conflicts.join("\n")}\nUse --replace-existing to back them up and replace them.`);
  for (const file of planned) log(`${options.dryRun ? "Would install" : "Install"}: ${file.path}`);
  log(`${options.dryRun ? "Would copy" : "Runtime"}: ${files.length} source files → ${release}`);
  if (options.dryRun) return { release, paths, started: false, dryRun: true };

  mkdirSync(join(paths.runtime, "releases"), { recursive: true });
  const stage = join(paths.runtime, `.stage-${randomUUID()}`);
  if (!existsSync(release)) {
    try {
      mkdirSync(stage);
      for (const file of files) { mkdirSync(dirname(join(stage, file)), { recursive: true }); cpSync(join(source, file), join(stage, file)); }
      checked(bun, ["install", "--cwd", join(stage, "packages/host-linux"), "--frozen-lockfile", "--ignore-scripts", "--omit", "optional"]);
      checked(bun, [join(stage, "bin/lattices.ts"), "help"], 15000);
      renameSync(stage, release);
    } finally { rmSync(stage, { recursive: true, force: true }); }
  }
  const oldApps = [...new Set([...(previous?.appReleases ?? []), ...(previous ? [previous.release] : [])])];
  for (const old of oldApps) {
    if (typeof old !== "string" || dirname(resolve(old)) !== resolve(join(paths.runtime, "releases"))) throw new Error("Invalid managed app path in the installation receipt.");
  }
  if (options.start) {
    // Each copied release is a distinct Quickshell app identity. Close the old
    // managed app before opening its replacement, including deferred SSH updates.
    for (const old of oldApps) checked(bun, [join(old, "bin/lattices.ts"), "app", "quit"], 15000);
  }
  const backup = join(paths.state, "lattices/install-backups", `${Date.now()}-${randomUUID().slice(0, 8)}`);
  const undo: Array<() => void> = [];
  const saveOld = (path: string) => {
    if (!present(path)) { undo.push(() => rmSync(path, { force: true })); return; }
    mkdirSync(backup, { recursive: true, mode: 0o700 });
    const saved = join(backup, `${undo.length}-${path.split("/").pop()}`);
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) symlinkSync(readlinkSync(path), saved); else cpSync(path, saved);
    undo.push(() => { rmSync(path, { force: true }); cpSync(saved, path, { dereference: false, verbatimSymlinks: true }); });
  };
  const atomic = (path: string, content: string, mode: number) => {
    mkdirSync(dirname(path), { recursive: true }); saveOld(path);
    const temporary = path + `.install-${randomUUID()}`;
    try { writeFileSync(temporary, content, { mode }); chmodSync(temporary, mode); renameSync(temporary, path); }
    finally { rmSync(temporary, { force: true }); }
  };
  try {
    mkdirSync(dirname(current), { recursive: true }); saveOld(current);
    const next = current + "." + randomUUID(); symlinkSync(relative(dirname(current), release), next); renameSync(next, current);
    for (const file of planned) {
      if (present(file.path) && !lstatSync(file.path).isSymbolicLink() && readFileSync(file.path, "utf8") === file.content) continue;
      atomic(file.path, file.content, file.mode);
    }
    const receipt: Receipt = { schema: 1, release, files: Object.fromEntries(planned.filter(file => !file.shared).map(file => [file.path, hash(file.content)])), backup, gestures: options.gestures, wheel: options.wheel, appReleases: options.start ? [] : oldApps };
    atomic(paths.receipt, JSON.stringify(receipt, null, 2) + "\n", 0o600);
    if (options.gestures) checked("Hyprland", ["--verify-config", "--config", join(paths.config, "hypr/hyprland.lua")], 20000);
    if (options.start && options.gestures) {
      checked("hyprctl", ["reload"], 5000);
      const errors = checked("hyprctl", ["configerrors"], 5000).stdout.trim();
      if (errors) throw new Error(`Hyprland rejected the gesture config: ${errors}`);
    }
  } catch (error) {
    for (const restore of undo.reverse()) restore();
    if (options.start && options.gestures) run("hyprctl", ["reload"], 5000);
    throw error;
  }
  log(`Files installed. Backups: ${backup}`);
  if (!options.start) {
    log("Services were not started. From a Hyprland terminal, rerun without --no-start to activate and verify the installation.");
    return { release, paths, started: false, gestureRelease };
  }
  // Files are committed now. A service/health failure keeps this usable install
  // and reports recovery; it never claims a healthy desktop or rolls back data.
  try {
    checked("systemctl", ["--user", "import-environment", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "XDG_CURRENT_DESKTOP"], 5000);
    checked("systemctl", ["--user", "daemon-reload"], 5000);
    checked("systemctl", ["--user", "enable", "lattices-host.service", "lattices-tray.service"], 10000);
    checked("systemctl", ["--user", "restart", "lattices-host.service", "lattices-tray.service"], 15000);
    let doctor: CommandResult = { status: 1, stdout: "", stderr: "Host has not replied" };
    for (let attempt = 0; attempt < 8; ++attempt) {
      doctor = run(launcher, ["--host", "127.0.0.1:9399", "doctor", "--json"], 10000);
      if (doctor.status === 0) break;
      await Bun.sleep(250);
    }
    if (doctor.status !== 0) throw new Error(doctor.stdout || doctor.stderr);
    const health = JSON.parse(doctor.stdout);
    if (health.ok !== true) throw new Error(doctor.stdout);
    checked(launcher, ["app"], 15000);
    log("Lattices is installed. Host health passed; host and tray start at login. The app was opened.");
    return { release, paths, started: true, gestureRelease };
  } catch (error) {
    throw new Error(`Files are installed, but activation did not finish: ${(error as Error).message}\nRun lats --host 127.0.0.1:9399 doctor and journalctl --user -u lattices-host -u lattices-tray. Rerun the installer from your Hyprland desktop.`);
  }
}

if (import.meta.main) {
  try {
    if (process.argv.slice(2).some(arg => arg === "--help" || arg === "-h")) console.log(usage);
    else await installLinux(parseOptions(process.argv.slice(2)));
  } catch (error) { console.error((error as Error).message); process.exitCode = 1; }
}
