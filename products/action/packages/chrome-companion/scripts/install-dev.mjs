#!/usr/bin/env bun

import { access } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { profileName, profileDir } from "./mira-chrome.mjs";

const rootPath = fileURLToPath(new URL("..", import.meta.url));
const distPath = join(rootPath, "dist");

const build = spawnSync("bun", ["scripts/build.mjs"], {
  cwd: rootPath,
  stdio: "inherit",
});

if (build.status !== 0) {
  process.exit(build.status ?? 1);
}

await access(distPath);

const launch = spawnSync("bun", ["scripts/profile.mjs", "launch", profileName, "--url", "chrome://extensions"], {
  cwd: rootPath,
  stdio: "inherit",
});

if (launch.status !== 0) {
  process.exit(launch.status ?? 1);
}

spawnSync("open", ["-R", distPath], {
  stdio: "ignore",
});

console.log("");
console.log("Action Chrome Companion is built.");
console.log("");
console.log(`Opened chrome://extensions in the ${profileName} profile (not personal Chrome).`);
console.log("Chrome requires unpacked extensions to be approved in the UI:");
console.log("1. Enable Developer mode in chrome://extensions.");
console.log("2. Click Load unpacked.");
console.log(`3. Select ${distPath}.`);
console.log("");
console.log("Or run fully automated install:");
console.log("  bun run install:self");
console.log("");
console.log("Register the approved extension id with native messaging:");
console.log(`  bun scripts/install-native-host.mjs <extension-id> ${JSON.stringify(profileDir)}`);
console.log("This also installs the private bridge as a user LaunchAgent.");
console.log("Then run:");
console.log("  bun run health");
