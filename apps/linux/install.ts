import { createHash, randomUUID } from "node:crypto";
import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, symlinkSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseOptions, usage, type InstallOptions } from "./install/options.ts";
import { desktopQuote, installPaths, shellQuote } from "./install/paths.ts";
import type { InstallContext, PlannedFile, Receipt, Runner } from "./install/types.ts";
import { runtimeFiles } from "./install/runtime.ts";
import { checkOwnership, fileTransaction, hash, present } from "./install/files.ts";
import { activateInstall } from "./install/activation.ts";
import { planOmarchy } from "./integrations/omarchy/install.ts";
import { renderServiceUnit } from "../../packages/host-linux/src/service-units.ts";

export { parseOptions, usage, type InstallOptions } from "./install/options.ts";
export { desktopQuote, installPaths, shellQuote, type InstallPaths } from "./install/paths.ts";
export { unitQuote } from "../../packages/host-linux/src/service-units.ts";
export { runtimeFiles } from "./install/runtime.ts";
export { mergeBindings, mergeShell } from "./integrations/omarchy/install.ts";
export type { CommandResult, Runner } from "./install/types.ts";

const defaultRun: Runner = (command, args, timeout = 120000) => {
  const result = Bun.spawnSync([command, ...args], { stdout: "pipe", stderr: "pipe", timeout, env: { ...process.env, BUN_INSTALL_AUTO: "disable" } });
  return { status: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString() };
};

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
  for (const name of ["host", "tray"] as const) {
    const template = readFileSync(join(source, `packages/host-linux/systemd/lattices-${name}.service`), "utf8");
    add(join(paths.config, `systemd/user/lattices-${name}.service`), renderServiceUnit(template, name, {
      bun, entry: join(current, "packages/host-linux/src/main.ts"), environmentPath,
    }));
  }
  const gestureRelease = planOmarchy({ options, context, paths, source, launcher, which, checked, add });
  checkOwnership(planned, previous, current, options.replace);
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
  const { backup, saveOld, atomic, rollback } = fileTransaction(paths.state);
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
    rollback();
    if (options.start && options.gestures) run("hyprctl", ["reload"], 5000);
    throw error;
  }
  log(`Files installed. Backups: ${backup}`);
  if (!options.start) {
    log("Services were not started. From a Hyprland terminal, rerun without --no-start to activate and verify the installation.");
    return { release, paths, started: false, gestureRelease };
  }
  await activateInstall(launcher, checked, run, log);
  return { release, paths, started: true, gestureRelease };
}

if (import.meta.main) {
  try {
    if (process.argv.slice(2).some(arg => arg === "--help" || arg === "-h")) console.log(usage);
    else await installLinux(parseOptions(process.argv.slice(2)));
  } catch (error) { console.error((error as Error).message); process.exitCode = 1; }
}
