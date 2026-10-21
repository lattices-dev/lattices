#!/usr/bin/env bun
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { installBridgeAgent } from "./install-bridge-agent.mjs";

export function installNativeHost(extensionId, userDataDir = process.env.ACTION_CHROME_COMPANION_PROFILE_DIR ?? join(homedir(), "Library/Application Support/Action/ChromeProfiles/agent-layer")) {
  if (!/^[a-p]{32}$/.test(extensionId ?? "")) throw new Error("Pass the approved Action Chrome Companion extension id (32 letters a-p)");
  if (!isAbsolute(userDataDir)) throw new Error("Pass the browser's absolute user-data-dir as the second argument");
  const directory = join(userDataDir, "NativeMessagingHosts");
  const launcherDir = join(homedir(), "Library/Application Support/Action/native-messaging");
  mkdirSync(directory, { recursive: true }); mkdirSync(launcherDir, { recursive: true, mode: 0o700 });
  const launcher = join(launcherDir, "chrome-companion");
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  const script = fileURLToPath(new URL("./native-host.mjs", import.meta.url));
  writeFileSync(launcher, `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(script)}\n`, { mode: 0o700 });
  chmodSync(launcherDir, 0o700); chmodSync(launcher, 0o700);
  const manifest = join(directory, "dev.lattices.action.chrome.json");
  writeFileSync(manifest, JSON.stringify({ name: "dev.lattices.action.chrome", description: "Action private Chrome companion", path: launcher, type: "stdio", allowed_origins: [`chrome-extension://${extensionId}/`] }, null, 2) + "\n", { mode: 0o600 });
  chmodSync(manifest, 0o600);
  installBridgeAgent();
}
if (import.meta.main) { installNativeHost(process.argv[2], process.argv[3]); console.log("Installed Action native messaging host for the approved extension."); }
