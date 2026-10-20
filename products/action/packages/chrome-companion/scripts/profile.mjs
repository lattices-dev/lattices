#!/usr/bin/env bun

import { chromeCompanionRequest } from "../../runtime/src/chrome-companion-ipc.ts";
import { mkdir, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const rootPath = fileURLToPath(new URL("..", import.meta.url));
const distPath = join(rootPath, "dist");
const defaultProfileRoot = join(homedir(), "Library/Application Support/Action/ChromeProfiles");
const chromeAppName = process.env.ACTION_CHROME_APP_NAME || "Google Chrome";
const command = process.argv[2] || "help";
const args = process.argv.slice(3);

const parsed = parseArgs(args);
const profileName = parsed.name || parsed.positionals[0] || process.env.ACTION_CHROME_COMPANION_PROFILE || "default";
const profileRoot = process.env.ACTION_CHROME_COMPANION_PROFILE_ROOT || defaultProfileRoot;
const profileDir = process.env.ACTION_CHROME_COMPANION_PROFILE_DIR || join(profileRoot, profileName);
const debugPort = parsed.debugPort || process.env.ACTION_CHROME_COMPANION_DEBUG_PORT || "9333";
const initialURL = parsed.url || process.env.ACTION_CHROME_COMPANION_URL || "https://www.midjourney.com/imagine";
const extensionId = parsed.extensionId || process.env.ACTION_CHROME_COMPANION_EXTENSION_ID;

switch (command) {
  case "setup":
    await buildExtension();
    await createProfile();
    openExtensionsPage();
    revealExtensionDist();
    printSetupGuide();
    break;
  case "launch":
    await buildExtension();
    await createProfile();
    launchProfile(initialURL);
    if (extensionId) {
      await openBridgePage(extensionId);
    }
    printLaunchSummary();
    break;
  case "check":
    await checkProfile();
    break;
  case "bridge":
    if (!extensionId) {
      console.error("Missing extension id. Pass --extension-id or ACTION_CHROME_COMPANION_EXTENSION_ID.");
      process.exit(1);
    }
    await openBridgePage(extensionId);
    console.log(`Opened bridge page for ${extensionId}.`);
    break;
  case "import-cookies": {
    const importArgs = ["scripts/import-cookies.mjs", ...args];
    const hasInto = args.some((value) => value === "--into" || value === "--profile" || value === "--to");
    if (!hasInto) {
      importArgs.push("--into", profileName);
    }
    const importRun = spawnSync("bun", importArgs, { cwd: rootPath, stdio: "inherit" });
    process.exit(importRun.status ?? 1);
    break;
  }
  case "path":
    console.log(profileDir);
    break;
  case "help":
  default:
    printHelp();
    process.exit(command === "help" ? 0 : 1);
}

async function buildExtension() {
  const build = spawnSync("bun", ["scripts/build.mjs"], {
    cwd: rootPath,
    stdio: "inherit",
  });

  if (build.status !== 0) {
    process.exit(build.status ?? 1);
  }
}

async function createProfile() {
  await mkdir(profileDir, { recursive: true });
  await writeFile(
    join(profileDir, ".action-profile.json"),
    `${JSON.stringify({
      name: profileName,
      profileDir,
      extensionDist: distPath,
      debugPort,
      updatedAt: new Date().toISOString(),
    }, null, 2)}\n`,
  );
}

function launchProfile(url) {
  const launch = spawnSync("open", [
    "-n",
    "-a",
    chromeAppName,
    "--args",
    `--user-data-dir=${profileDir}`,
    "--no-first-run",
    "--no-default-browser-check",
    `--remote-debugging-port=${debugPort}`,
    "--new-window",
    url,
  ], { stdio: "inherit" });

  if (launch.status !== 0) {
    process.exit(launch.status ?? 1);
  }
}

function openExtensionsPage() {
  launchProfile("chrome://extensions");
}

function revealExtensionDist() {
  spawnSync("open", ["-R", distPath], { stdio: "ignore" });
}

async function openBridgePage(id) {
  const bridgeURL = `chrome-extension://${id}/bridge.html`;
  await waitForDebugPort();
  await fetch(`http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(bridgeURL)}`, {
    method: "PUT",
  }).catch(() => undefined);
}

async function checkProfile() {
  const summary = {
    profileName,
    profileDir,
    profileExists: existsSync(profileDir),
    extensionDist: distPath,
    extensionDistExists: existsSync(distPath),
    debugPort,
    chromeDebuggable: false,
    companionTargets: [],
    companionExtensionIds: [],
    bridgeHealth: undefined,
  };

  try {
    const response = await fetch(`http://127.0.0.1:${debugPort}/json/list`);
    const targets = await response.json();
    summary.chromeDebuggable = true;
    summary.companionTargets = targets
      .filter((target) => typeof target.url === "string" && target.url.includes("chrome-extension://"))
      .map((target) => ({ type: target.type, title: target.title, url: target.url }));
    summary.companionExtensionIds = [
      ...new Set(summary.companionTargets
        .filter((target) => target.url.endsWith("/service_worker.js") || target.url.endsWith("/bridge.html"))
        .map((target) => target.url.match(/^chrome-extension:\/\/([^/]+)\//)?.[1])
        .filter(Boolean)),
    ];
  } catch {
    // Chrome may not be running for this profile yet.
  }

  try {
    summary.bridgeHealth = await chromeCompanionRequest("/health");
  } catch {
    summary.bridgeHealth = { ok: false, connected: false, error: "Bridge server is not reachable." };
  }

  console.log(JSON.stringify(summary, null, 2));
  process.exit(summary.profileExists && summary.extensionDistExists ? 0 : 1);
}

async function waitForDebugPort() {
  for (let attempt = 0; attempt < 24; attempt += 1) {
    try {
      await fetch(`http://127.0.0.1:${debugPort}/json/version`);
      return;
    } catch {
      await Bun.sleep(250);
    }
  }
}

function printSetupGuide() {
  console.log("");
  console.log(`Created Action Chrome profile: ${profileName}`);
  console.log(`Profile: ${profileDir}`);
  console.log(`Extension dist: ${distPath}`);
  console.log("");
  console.log("Manual step needed in the Action Chrome window:");
  console.log("1. Enable Developer mode.");
  console.log("2. Click Load unpacked.");
  console.log(`3. Select ${distPath}.`);
  console.log("");
  console.log("After installing the extension, run:");
  console.log(`  ACTION_CHROME_COMPANION_PROFILE=${profileName} bun run profile -- check`);
  console.log("  bun run bridge");
}

function printLaunchSummary() {
  console.log("");
  console.log(`Launched Action Chrome profile: ${profileName}`);
  console.log(`Profile: ${profileDir}`);
  console.log(`Debug port: ${debugPort}`);
  if (extensionId) {
    console.log(`Bridge page: chrome-extension://${extensionId}/bridge.html`);
  }
}

function printHelp() {
  console.log(`Usage:
  bun run profile -- setup [name]
  bun run profile -- launch [name] [--url URL]
  bun run profile -- bridge [name] --extension-id EXTENSION_ID
  bun run profile -- import-cookies list --into NAME --domains DOMAIN
  bun run profile -- import-cookies import --into NAME --domains DOMAIN --only COOKIE --confirm
  bun run profile -- import-cookies --list-action-profiles
  bun run profile -- import-cookies --list-profiles
  bun run profile -- check [name]
  bun run profile -- path [name]

Named Action profiles live under:
  ~/Library/Application Support/Action/ChromeProfiles/<name>

Cookie seeding (selective, not full-profile clone):
  bun run profile -- import-cookies import --into work --source "Profile 1" --domains github.com --confirm

Companion extension (load unpacked once per profile):
  bun run profile -- setup work
  # then Load unpacked -> packages/chrome-companion/dist

Environment:
  ACTION_CHROME_COMPANION_PROFILE       Profile name, default: default
  ACTION_CHROME_COMPANION_PROFILE_DIR   Absolute profile directory override
  ACTION_CHROME_COMPANION_PROFILE_ROOT  Profiles root override
  ACTION_CHROME_COMPANION_DEBUG_PORT    Chrome remote debugging port, default: 9333
  ACTION_CHROME_COMPANION_EXTENSION_ID  Open bridge page after launch
  ACTION_BROWSER_PROFILE                Alias used by Action Browser MCP
`);
}

function parseArgs(values) {
  const result = {
    positionals: [],
    name: undefined,
    url: undefined,
    debugPort: undefined,
    extensionId: undefined,
  };

  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value === "--name") {
      result.name = values[index + 1];
      index += 1;
    } else if (value === "--url") {
      result.url = values[index + 1];
      index += 1;
    } else if (value === "--debug-port") {
      result.debugPort = values[index + 1];
      index += 1;
    } else if (value === "--extension-id") {
      result.extensionId = values[index + 1];
      index += 1;
    } else if (!value.startsWith("--")) {
      result.positionals.push(value);
    }
  }

  if (result.url) {
    result.url = normalizeURL(result.url);
  }
  if (process.env.ACTION_CHROME_COMPANION_PROFILE_DIR) {
    process.env.ACTION_CHROME_COMPANION_PROFILE_DIR = resolve(process.env.ACTION_CHROME_COMPANION_PROFILE_DIR);
  }
  return result;
}

function normalizeURL(value) {
  if (/^[a-z]+:\/\//i.test(value) || value.startsWith("chrome://")) {
    return value;
  }
  return `https://${value}`;
}
