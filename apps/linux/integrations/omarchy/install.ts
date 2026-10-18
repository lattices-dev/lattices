import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { InstallOptions } from "../../install/options.ts";
import type { InstallPaths } from "../../install/paths.ts";
import type { AddFile, CheckedRunner, InstallContext } from "../../install/types.ts";
import { walk } from "../../install/runtime.ts";

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

export function planOmarchy({ options, context, paths, source, launcher, which, checked, add }: {
  options: InstallOptions; context: InstallContext; paths: InstallPaths; source: string;
  launcher: string; which: (command: string) => string | null; checked: CheckedRunner; add: AddFile;
}): string | null {
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
    const module = readFileSync(join(source, "apps/linux/integrations/omarchy/lattices-mouse.lua.in"), "utf8")
      .replace("@LATS@", JSON.stringify(launcher)).replace("@SPACE_HELPER@", JSON.stringify(join(paths.bin, "lattices-gesture-space")))
      .replace("@FAB@", JSON.stringify(which("fab-linux") ?? join(paths.bin, "fab-linux"))).replace("@BUTTONS@", buttons);
    add(join(paths.config, "hypr/lattices-mouse.lua"), module);
    const helper = readFileSync(join(source, "apps/linux/integrations/omarchy/lattices-gesture-space.py.in"), "utf8").replace("@LATS_PYTHON@", JSON.stringify(launcher));
    add(join(paths.bin, "lattices-gesture-space"), helper, 0o755);
    const bindings = join(paths.config, "hypr/bindings.lua"), shell = join(paths.config, "omarchy/shell.json");
    add(bindings, mergeBindings(existsSync(bindings) ? readFileSync(bindings, "utf8") : ""), 0o644, true);
    add(shell, mergeShell(existsSync(shell) ? readFileSync(shell, "utf8") : ""), 0o644, true);
    const pluginSource = join(source, "apps/linux/integrations/omarchy/plugin"), pluginRoot = join(paths.config, "omarchy/plugins/lattices.gestures");
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
  return gestureRelease;
}
