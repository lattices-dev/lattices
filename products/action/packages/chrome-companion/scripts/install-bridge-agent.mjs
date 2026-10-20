#!/usr/bin/env bun
import { chmodSync, copyFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

export function installBridgeAgent() {
  if (process.platform !== "darwin" || typeof process.getuid !== "function") throw new Error("The private Chrome bridge LaunchAgent requires macOS");
  const label = "dev.lattices.action.chrome-bridge";
  const support = join(homedir(), "Library/Application Support/Action");
  const logs = join(support, "logs");
  const directory = join(homedir(), "Library/LaunchAgents");
  const plist = join(directory, `${label}.plist`);
  mkdirSync(directory, { recursive: true });
  mkdirSync(logs, { recursive: true, mode: 0o700 });
  const definition = {
    Label: label,
    ProgramArguments: [process.execPath, fileURLToPath(new URL("./bridge-server.mjs", import.meta.url))],
    WorkingDirectory: fileURLToPath(new URL("..", import.meta.url)),
    RunAtLoad: true,
    KeepAlive: true,
    ThrottleInterval: 5,
    ProcessType: "Background",
    EnvironmentVariables: { HOME: homedir(), LATTICES_RUNTIME_DIR: join(homedir(), ".lattices/run") },
    StandardOutPath: join(logs, "chrome-bridge.log"),
    StandardErrorPath: join(logs, "chrome-bridge.log"),
  };
  const converted = spawnSync("/usr/bin/plutil", ["-convert", "xml1", "-o", "-", "--", "-"], { input: JSON.stringify(definition), encoding: "utf8" });
  if (converted.status !== 0) throw new Error(converted.stderr || "Could not encode LaunchAgent");
  if (existsSync(plist)) copyFileSync(plist, join(support, `${label}.${Date.now()}.backup.plist`));
  writeFileSync(plist, converted.stdout, { mode: 0o600 });
  chmodSync(plist, 0o600);
  const domain = `gui/${process.getuid()}`;
  spawnSync("/bin/launchctl", ["bootout", `${domain}/${label}`], { stdio: "ignore" });
  const result = spawnSync("/bin/launchctl", ["bootstrap", domain, plist], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr || "Could not load private Chrome bridge LaunchAgent");
  console.log(`Installed private Chrome bridge LaunchAgent: ${plist}`);
}

if (import.meta.main) installBridgeAgent();
