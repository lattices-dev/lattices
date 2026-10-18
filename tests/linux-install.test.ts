import { afterEach, expect, test } from "bun:test";
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { desktopQuote, installLinux, installPaths, mergeBindings, mergeShell, parseOptions, unitQuote, type CommandResult, type Runner } from "../apps/linux/install.ts";

const linuxTest = process.platform === "linux" ? test : test.skip;
const root = fileURLToPath(new URL("../", import.meta.url));
const cleanup: string[] = [];
afterEach(() => { for (const dir of cleanup.splice(0)) rmSync(dir, { recursive: true, force: true }); });
function fixture(name = "home") {
  const dir = mkdtempSync(join(tmpdir(), "lattices-install-")); cleanup.push(dir);
  const home = join(dir, name), source = join(dir, "source");
  mkdirSync(home);
  for (const path of ["bin", "apps/linux", "packages/host-linux/src", "packages/host-linux/visitor", "packages/npm/sdk", "docs", "assets"]) mkdirSync(join(source, path), { recursive: true });
  for (const path of ["package.json", "packages/host-linux/package.json"]) writeFileSync(join(source, path), '{"name":"fixture","version":"1.0.0"}');
  writeFileSync(join(source, "packages/host-linux/bun.lock"), "{}");
  for (const path of ["packages/host-linux/src/main.ts", "packages/host-linux/visitor/shell.qml", "packages/npm/sdk/cua.mjs", "docs/quickstart.md"]) writeFileSync(join(source,path), "// fixture");
  writeFileSync(join(source, "bin/lattices.ts"), 'console.log("fixture CLI")');
  writeFileSync(join(source, "assets/logo-mark.svg"), '<svg xmlns="http://www.w3.org/2000/svg"/>');
  cpSync(join(root, "apps/linux/integrations/omarchy"), join(source, "apps/linux/integrations/omarchy"), { recursive: true });
  cpSync(join(root, "packages/host-linux/systemd"), join(source, "packages/host-linux/systemd"), { recursive: true });
  cpSync(join(root, "packages/desktop-client"), join(source, "packages/desktop-client"), { recursive: true });
  cpSync(join(root, "apps/linux/lattices.desktop"), join(source, "apps/linux/lattices.desktop"));
  const paths = installPaths({ HOME: home });
  const omarchy = join(dir, "omarchy"); mkdirSync(join(omarchy, "default/hypr"), { recursive: true }); writeFileSync(join(omarchy, "default/hypr/helpers.lua"), "-- fixture");
  mkdirSync(join(paths.config, "hypr"), { recursive: true }); writeFileSync(join(paths.config, "hypr/hyprland.lua"), '-- Omarchy fixture');
  const commands: Array<[string, string[]]> = [];
  const run: Runner = (command, args) => {
    commands.push([command, args]);
    return { status: 0, stdout: args.includes("doctor") ? '{"ok":true}' : command === "Hyprland" && args.includes("--version") ? "Hyprland 0.56.2" : "", stderr: "" };
  };
  const context = { source, paths, omarchy, run, which: (name: string) => "/usr/bin/" + name, bun: process.execPath, log: (_: string) => {} };
  return { dir, home, source, paths, omarchy, commands, context };
}
const options = () => parseOptions(["--no-start"]);

test("installer rejects unknown options and keeps wheel gestures explicit", () => {
  expect(() => parseOptions(["--wat"])).toThrow("Unknown option");
  expect(parseOptions([])).toMatchObject({ gestures: false, wheel: false, start: true });
  expect(parseOptions(["--wheel-gestures"])).toMatchObject({ gestures: true, wheel: true });
  expect(unitQuote('/tmp/a b/%$"\\')).toBe('"/tmp/a b/%%$$\\"\\\\"');
  expect(() => unitQuote("bad\narg")).toThrow();
  expect(unitQuote("PATH=/tmp/$user", false)).toBe('"PATH=/tmp/$user"');
  expect(desktopQuote('/tmp/a b/$x%')).toBe('"/tmp/a b/\\\\$x%%"');
});

linuxTest("dry-run writes nothing and does not run package, service, or desktop commands", async () => {
  const f = fixture(); const before = readdirSync(f.home);
  await installLinux(parseOptions(["--dry-run", "--gestures"]), f.context);
  expect(f.commands).toEqual([]);
  expect(readdirSync(f.home)).toEqual(before);
  expect(existsSync(f.paths.runtime)).toBe(false);
  expect(existsSync(join(f.paths.config, "hypr/bindings.lua"))).toBe(false);
});

linuxTest("install creates a checkout-independent runtime and repeatable Omarchy config", async () => {
  const f = fixture("a home ' $% space");
  mkdirSync(join(f.paths.config, "omarchy"), { recursive: true });
  const shell = join(f.paths.config, "omarchy/shell.json"), bindings = join(f.paths.config, "hypr/bindings.lua");
  writeFileSync(shell, JSON.stringify({ bar: { keep: true }, plugins: [{ id: "scout.linux" }] }));
  writeFileSync(bindings, '-- personal bindings\n');
  const choice = parseOptions(["--no-start", "--wheel-gestures"]);
  const first = await installLinux(choice, f.context);
  const module = readFileSync(join(f.paths.config, "hypr/lattices-mouse.lua"), "utf8");
  expect(module).toContain('"mouse:274"'); expect(module).toContain('key = "Return"'); expect(module).not.toContain('@LATS@');
  expect(JSON.parse(readFileSync(shell, "utf8"))).toEqual({ bar: { keep: true }, plugins: [{ id: "scout.linux" }, { id: "lattices.gestures" }] });
  expect(f.commands.some(([,args]) => args.includes("--ignore-scripts") && args.includes("--frozen-lockfile"))).toBe(true);
  expect(f.commands.some(([command]) => command === "systemctl" || command === "hyprctl")).toBe(false);
  rmSync(f.source, { recursive: true });
  const installed = join(first.release, "bin/lattices.ts");
  expect(existsSync(installed)).toBe(true);
  const launcher = Bun.spawnSync([join(f.paths.bin, "lats"), "help"], { stdout: "pipe", stderr: "pipe" });
  expect(launcher.exitCode).toBe(0); expect(launcher.stdout.toString()).toContain("fixture CLI");
  const second = await installLinux(options(), { ...f.context, source: first.release });
  expect(second.release).toBe(first.release);
  expect(JSON.parse(readFileSync(shell, "utf8")).plugins).toHaveLength(2);
  expect(readFileSync(bindings, "utf8").match(/BEGIN LATTICES GESTURES/g)).toHaveLength(1);
  expect(JSON.parse(readFileSync(f.paths.receipt, "utf8"))).toMatchObject({ gestures: true, wheel: true });
  await installLinux(parseOptions(["--no-start","--gestures"]),{...f.context,source:first.release});
  expect(JSON.parse(readFileSync(f.paths.receipt,"utf8"))).toMatchObject({gestures:true,wheel:false});
});

linuxTest("unowned files and modified owned files need explicit replacement before any writes", async () => {
  const f = fixture(); mkdirSync(f.paths.bin, { recursive: true });
  writeFileSync(join(f.paths.bin, "lats"), "personal CLI");
  await expect(installLinux(options(), f.context)).rejects.toThrow("Existing files need review");
  expect(existsSync(f.paths.runtime)).toBe(false); expect(f.commands).toEqual([]);
  const result = await installLinux(parseOptions(["--no-start", "--replace-existing"]), f.context);
  const receipt = JSON.parse(readFileSync(f.paths.receipt, "utf8"));
  expect(readdirSync(receipt.backup).some(name => readFileSync(join(receipt.backup, name), "utf8") === "personal CLI")).toBe(true);
  writeFileSync(join(f.paths.bin, "lats"), "changed by owner");
  await expect(installLinux(options(), { ...f.context, source: result.release })).rejects.toThrow("Existing files need review");
  expect(readFileSync(join(f.paths.bin, "lats"), "utf8")).toBe("changed by owner");
});

linuxTest("dependency failure leaves launchers and desktop config untouched", async () => {
  const f = fixture();
  const run: Runner = () => ({ status: 1, stdout: "", stderr: "dependency download failed" });
  await expect(installLinux(options(), { ...f.context, run })).rejects.toThrow("dependency download failed");
  expect(existsSync(join(f.paths.bin, "lats"))).toBe(false);
  expect(existsSync(join(f.paths.config, "systemd/user/lattices-host.service"))).toBe(false);
  expect(existsSync(f.paths.receipt)).toBe(false);
  expect(readdirSync(f.paths.runtime).some(name => name.startsWith('.stage'))).toBe(false);
});

linuxTest("a rejected live gesture config rolls back files and the current runtime link", async () => {
  const f = fixture();
  const initial = await installLinux(options(), f.context);
  const oldLink = readlinkSync(join(f.paths.runtime, "current"));
  writeFileSync(join(f.source, "docs/update.md"), "new revision");
  const run: Runner = (command, args) => args.includes("configerrors") ? { status: 0, stdout: "bad gesture config", stderr: "" } : f.context.run(command, args);
  await expect(installLinux(parseOptions(["--gestures"]), { ...f.context, run })).rejects.toThrow("Hyprland rejected");
  expect(readlinkSync(join(f.paths.runtime, "current"))).toBe(oldLink);
  expect(JSON.parse(readFileSync(f.paths.receipt, "utf8")).release).toBe(initial.release);
  expect(existsSync(join(f.paths.config, "hypr/lattices-mouse.lua"))).toBe(false);
  expect(existsSync(join(f.paths.config, "hypr/bindings.lua"))).toBe(false);
});

linuxTest("starting installs imports the session, enables services, checks doctor, then opens the app", async () => {
  const f = fixture();
  const result = await installLinux(parseOptions([]), f.context);
  expect(result.started).toBe(true);
  const actions = f.commands.map(([command,args]) => command + ' ' + args.join(' '));
  expect(actions.some(command => command.includes('systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE'))).toBe(true);
  expect(actions.some(command => command.includes('systemctl --user enable lattices-host.service lattices-tray.service'))).toBe(true);
  expect(actions.at(-2)).toContain('--host 127.0.0.1:9399 doctor --json');
  expect(actions.at(-1)).toEndWith('lats app');
});

linuxTest("activation failure reports the installed state and does not claim success", async () => {
  const f = fixture();
  const run: Runner = (command,args) => args.includes('restart') ? { status: 1, stdout: '', stderr: 'service failed' } : f.context.run(command,args);
  await expect(installLinux(parseOptions([]), { ...f.context, run })).rejects.toThrow('Files are installed, but activation did not finish');
  expect(existsSync(f.paths.receipt)).toBe(true);
});

linuxTest("merges preserve independent plugin settings and reject malformed config and symlink edits", async () => {
  const shell = '{"plugins":[{"id":"lattices.gestures","keep":true}]}';
  expect(mergeShell(shell)).toBe(shell);
  expect(mergeBindings(mergeBindings('-- keep'))).toBe(mergeBindings('-- keep'));
  expect(() => mergeShell('{"plugins":{}}')).toThrow();
  expect(() => mergeBindings('o.bind("SUPER + CTRL + G", "mine", callback)')).toThrow('already configured');
  const f = fixture(); const external = join(f.dir,'external.lua'); writeFileSync(external,'keep');
  symlinkSync(external,join(f.paths.config,'hypr/bindings.lua'));
  await expect(installLinux(parseOptions(['--gestures','--no-start']),f.context)).rejects.toThrow('Config file is a symlink');
  expect(readFileSync(external,'utf8')).toBe('keep');
});

linuxTest("the public shell entry routes Linux help and dry-run without requiring Bun downloads", () => {
  const f=fixture();
  const env={...process.env,HOME:f.home,XDG_CONFIG_HOME:f.paths.config,XDG_DATA_HOME:f.paths.data,XDG_STATE_HOME:f.paths.state};
  const help=Bun.spawnSync(["bash",join(root,"install.sh"),"--help"],{env,stdout:"pipe",stderr:"pipe"});
  expect(help.exitCode).toBe(0); expect(help.stdout.toString()).toContain("Install Lattices on Linux");
  const preview=Bun.spawnSync(["bash",join(root,"install.sh"),"--dry-run","--no-start"],{env,stdout:"pipe",stderr:"pipe"});
  expect(preview.exitCode).toBe(0); expect(preview.stdout.toString()).toContain("Would copy");
  expect(existsSync(f.paths.runtime)).toBe(false);
});

linuxTest("older compositors are rejected before installing gesture config", async () => {
  const f=fixture();
  const run:Runner=(command,args)=>command==='Hyprland'&&args.includes('--version')?{status:0,stdout:'Hyprland 0.54.0',stderr:''}:f.context.run(command,args);
  await expect(installLinux(parseOptions(['--no-start','--gestures']),{...f.context,run})).rejects.toThrow('0.56 or later');
  expect(existsSync(f.paths.runtime)).toBe(false);
});

linuxTest("a failed standalone download returns failure instead of running an empty installer", () => {
  const f=fixture(), bootstrap=join(f.dir,'install.sh'), tools=join(f.dir,'tools');
  cpSync(join(root,'install.sh'),bootstrap); mkdirSync(tools);
  writeFileSync(join(tools,'curl'),'#!/bin/sh\nexit 22\n',{mode:0o755});
  const result=Bun.spawnSync(['bash',bootstrap],{env:{...process.env,PATH:tools+':'+process.env.PATH},stdout:'pipe',stderr:'pipe'});
  expect(result.exitCode).toBe(22);
});

linuxTest("a deferred update closes prior managed app releases before opening the replacement", async () => {
  const f=fixture();
  const first=await installLinux(options(),f.context);
  writeFileSync(join(f.source,'docs/update.md'),'new app release');
  const second=await installLinux(options(),f.context);
  expect(f.commands.some(([,args])=>args[1]==='app'&&args[2]==='quit')).toBe(false);
  expect(JSON.parse(readFileSync(f.paths.receipt,'utf8')).appReleases).toContain(first.release);
  await installLinux(parseOptions([]),{...f.context,source:second.release});
  const quits=f.commands.filter(([,args])=>args[1]==='app'&&args[2]==='quit');
  expect(quits.map(([,args])=>args[0])).toEqual([join(first.release,'bin/lattices.ts'),join(second.release,'bin/lattices.ts')]);
  expect(JSON.parse(readFileSync(f.paths.receipt,'utf8')).appReleases).toEqual([]);
});

// These boundaries require no Linux desktop, user bus or process.platform override.
// Keep the actual installation/activation cases above Linux-only.
test("file transaction restores owned content, mode, symlinks and absent files", async () => {
  const { fileTransaction, checkOwnership, hash } = await import("../apps/linux/install/files.ts");
  const f = fixture();
  const owned = join(f.home, "owned"), link = join(f.home, "link"), added = join(f.home, "added");
  writeFileSync(owned, "before", { mode: 0o600 });
  symlinkSync("owned", link);
  const planned = [{ path: owned, content: "after", mode: 0o644 }];
  expect(() => checkOwnership(planned, null, join(f.home, "current"), false)).toThrow("Existing files need review");
  checkOwnership(planned, { schema: 1, release: "old", files: { [owned]: hash("before") }, backup: "", gestures: false, wheel: false }, join(f.home, "current"), false);
  const transaction = fileTransaction(f.paths.state);
  transaction.atomic(owned, "after", 0o644);
  transaction.atomic(link, "replaced", 0o644);
  transaction.atomic(added, "new", 0o644);
  transaction.rollback();
  expect(readFileSync(owned, "utf8")).toBe("before");
  expect(lstatSync(owned).mode & 0o777).toBe(0o600);
  expect(readlinkSync(link)).toBe("owned");
  expect(existsSync(added)).toBe(false);
});

test("shared unit renderer preserves standalone bytes and development service policy", async () => {
  const { renderServiceUnit } = await import("../packages/host-linux/src/service-units.ts");
  const bun = '/home/a $% b/bun', entry = '/home/a $% b/runtime/packages/host-linux/src/main.ts';
  const environmentPath = '/home/a $% b/bin:/usr/bin';
  for (const name of ["host", "tray"] as const) {
    const template = readFileSync(join(root, `packages/host-linux/systemd/lattices-${name}.service`), "utf8");
    const command = `${unitQuote(bun)} ${unitQuote(entry)} ${name === "tray" ? "tray" : "--quiet"}`;
    expect(renderServiceUnit(template, name, { bun, entry })).toBe(template.replace(/^ExecStart=.*$/m, () => `ExecStart=${command}`));
    expect(renderServiceUnit(template, name, { bun, entry, environmentPath })).toBe(`[Unit]\nDescription=Lattices ${name}\nPartOf=graphical-session.target\nAfter=graphical-session.target\n\n[Service]\nExecStart=${command}\nEnvironment=${unitQuote("PATH=" + environmentPath, false)}\nRestart=on-failure\nRestartSec=3\n\n[Install]\nWantedBy=graphical-session.target\n`);
  }
});
