#!/usr/bin/env bun
import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { changeUnit, managerCall, withUserBus } from "../src/systemd.ts";

// systemd links rendered units from this checkout. It owns the user unit
// symlinks; the installer never edits Omarchy or Hyprland config.
export function unitArgument(value: string): string {
  if (/[\r\n\0]/.test(value)) throw new Error("Invalid service path");
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("%", "%%").replaceAll("$", () => "$$")}"`;
}

async function install() {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const rendered = join(root, ".systemd");
  const config = process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config");
  await mkdir(rendered, { recursive: true });
  const units = ["lattices-host.service", "lattices-tray.service"];
  const paths: string[] = [];
  for (const unit of units) {
    const path = join(rendered, unit);
    try {
      const existing = await realpath(join(config, "systemd/user", unit));
      if (existing !== path) throw new Error(`${unit} already installed from ${existing}`);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    const template = await readFile(join(root, "systemd", unit), "utf8");
    const command = `${unitArgument(process.execPath)} ${unitArgument(join(root, "src/main.ts"))}${unit === "lattices-tray.service" ? " tray" : " --quiet"}`;
    await writeFile(path, template.replace(/^ExecStart=.*$/m, () => `ExecStart=${command}`), { mode: 0o644 });
    paths.push(path);
  }
  await withUserBus(async (bus) => {
    await managerCall(bus, "LinkUnitFiles", "asbb", [paths, false, false]);
    await managerCall(bus, "Reload");
    await managerCall(bus, "EnableUnitFiles", "asbb", [["lattices-tray.service"], false, false]);
    await changeUnit(bus, "lattices-tray.service", "RestartUnit");
  });
  console.log("Lattices tray installed and running. Host starts from the menu.");
}

if (import.meta.main) install().catch((error) => { console.error(String(error)); process.exit(1); });
