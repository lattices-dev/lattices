#!/usr/bin/env bun

// lattices action — install, launch, and drive the Action product
// (products/action → Action.app + ActionAgent on ws://127.0.0.1:4319)
//
// Commands:
//   lattices action              Status (installed version, running, agent)
//   lattices action install      Download the latest action-v* release DMG → /Applications
//   lattices action update       Same as install (reinstalls latest)
//   lattices action launch       Open Action.app
//   lattices action quit         Quit Action.app
//   lattices action call <m> [j] Raw Action agent call (params as JSON)
//   lattices action <cmd> [args] Forward to the Action CLI in a monorepo checkout

import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, createWriteStream } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { get } from "node:https";
import type { IncomingMessage } from "node:http";
import { actionAgentCall, isActionAgentRunning } from "./action-agent-client";
import { distribution } from "./distribution";

const __dirname = import.meta.dir;
const REPO = distribution.repository;
const ACTION_TAG_PREFIX = "action-v";
const ACTION_DMG_ASSET = "Action.dmg";
const ACTION_APP_NAME = "Action.app";
const ACTION_BUNDLE_ID = "dev.lattices.Action";
const INSTALL_PATH = `/Applications/${ACTION_APP_NAME}`;
const ACTION_SITE_URL = "https://lattices.dev/action";

type ReleaseAsset = { name: string; browser_download_url: string };
type Release = {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  assets: ReleaseAsset[];
};

// ── Helpers ──────────────────────────────────────────────────────────

function isRunning(): boolean {
  try {
    execFileSync("pgrep", ["-x", "Action"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function installedPath(): string | null {
  if (existsSync(INSTALL_PATH)) return INSTALL_PATH;
  // Respect LaunchServices registration outside /Applications (e.g. ~/Applications)
  try {
    const url = execFileSync(
      "mdfind", ["kMDItemCFBundleIdentifier == '" + ACTION_BUNDLE_ID + "'"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
    ).trim().split("\n")[0];
    if (url && existsSync(url)) return url;
  } catch {}
  return null;
}

function installedVersion(appPath: string): string | null {
  try {
    const plist = resolve(appPath, "Contents/Info.plist");
    const out = execFileSync(
      "/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString", plist],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
    ).trim();
    return out || null;
  } catch {
    return null;
  }
}

function quitApp(): boolean {
  const appPath = installedPath();
  if (!appPath) return false;
  const directory = mkdtempSync(join(tmpdir(), "action-quit-"));
  const reply = join(directory, "reply.json");
  try {
    // The native command distinguishes launchers from persistent display owners.
    // A bundle-wide Apple Event or pgrep cannot make that distinction.
    execFileSync("/usr/bin/open", ["-n", "-g", appPath, "--args", "quit-app", "--reply-file", reply], { stdio: "ignore" });
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      if (existsSync(reply)) {
        try { return JSON.parse(readFileSync(reply, "utf8")).status === "quit"; }
        catch { /* The helper may still be writing its reply. */ }
      }
      execFileSync("/bin/sleep", ["0.1"], { stdio: "ignore" });
    }
    return false;
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

/**
 * Locate an Action product checkout (products/action) when running inside the
 * lattices monorepo. Order: $ACTION_ROOT → this script's repo → cwd's git root.
 */
function findCheckout(): string | null {
  const candidates: string[] = [];
  if (process.env.ACTION_ROOT) candidates.push(process.env.ACTION_ROOT);
  candidates.push(resolve(__dirname, "../products/action"));
  candidates.push(join(homedir(), "Library/Application Support/Lattices/runtime/current/products/action"));
  try {
    const top = execFileSync("git", ["rev-parse", "--show-toplevel"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (top) candidates.push(resolve(top, "products/action"));
  } catch {}

  for (const dir of candidates) {
    if (existsSync(resolve(dir, "packages/cli/src/main.ts"))) return dir;
  }
  return null;
}

// ── GitHub release download ──────────────────────────────────────────

function httpsGet(url: string): Promise<IncomingMessage> {
  return new Promise((resolve, reject) => {
    get(url, { headers: { "User-Agent": "lattices" } }, (res) => {
      if (res.statusCode! >= 300 && res.statusCode! < 400 && res.headers.location) {
        return httpsGet(res.headers.location).then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        reject(new Error(`HTTP ${res.statusCode}`));
        res.resume();
        return;
      }
      resolve(res);
    }).on("error", reject);
  });
}

async function httpsJson<T>(url: string): Promise<T> {
  const res = await httpsGet(url);
  const chunks: Buffer[] = [];
  for await (const chunk of res) chunks.push(chunk as Buffer);
  return JSON.parse(Buffer.concat(chunks).toString());
}

async function downloadToFile(url: string, destination: string): Promise<void> {
  const res = await httpsGet(url);
  const ws = createWriteStream(destination);
  await new Promise<void>((resolve, reject) => {
    res.pipe(ws);
    ws.on("finish", resolve);
    ws.on("error", reject);
  });
}

async function latestActionRelease(): Promise<Release | null> {
  const releases = await httpsJson<Release[]>(
    `https://api.github.com/repos/${REPO}/releases?per_page=30`
  );
  return releases.find(
    (r) => !r.draft && !r.prerelease && r.tag_name.startsWith(ACTION_TAG_PREFIX)
  ) ?? null;
}

function installAppFromDmg(dmgPath: string): void {
  const mountPoint = mkdtempSync(join(tmpdir(), "action-mount-"));
  try {
    execFileSync(
      "hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint, dmgPath],
      { stdio: "pipe" }
    );
    const mountedApp = resolve(mountPoint, ACTION_APP_NAME);
    if (!existsSync(mountedApp)) {
      throw new Error(`${ACTION_APP_NAME} not found in mounted disk image`);
    }
    rmSync(INSTALL_PATH, { recursive: true, force: true });
    execFileSync("cp", ["-R", mountedApp, INSTALL_PATH]);
  } finally {
    try {
      execFileSync("hdiutil", ["detach", mountPoint, "-quiet"], { stdio: "pipe" });
    } catch {}
    rmSync(mountPoint, { recursive: true, force: true });
  }
}

async function install(shouldLaunch: boolean): Promise<void> {
  console.log("Finding latest Action release...");
  const release = await latestActionRelease();
  if (!release) {
    console.error(`No published Action release found (looking for ${ACTION_TAG_PREFIX}* tags).`);
    console.error(`Manual install: ${ACTION_SITE_URL}`);
    process.exit(1);
  }

  const asset = release.assets.find((a) => a.name === ACTION_DMG_ASSET);
  if (!asset) {
    console.error(`Release ${release.tag_name} has no ${ACTION_DMG_ASSET} asset.`);
    process.exit(1);
  }

  const version = release.tag_name.slice(ACTION_TAG_PREFIX.length);
  const existing = installedPath();
  if (existing && installedVersion(existing) === version) {
    console.log(`Action ${version} is already installed at ${existing} (matches published release version).`);
    console.log("This does not verify source-build or MCP parity. Run `lats action capabilities` and reconnect MCP after runtime updates.");
    if (shouldLaunch) launchApp();
    return;
  }

  console.log(`Downloading Action ${version}...`);
  const tempDir = mkdtempSync(join(tmpdir(), "action-download-"));
  const dmgPath = resolve(tempDir, asset.name);
  try {
    await downloadToFile(asset.browser_download_url, dmgPath);

    if (isRunning()) {
      console.log("Quitting running Action...");
      if (!quitApp()) {
        throw new Error("Action did not quit. The installed app was left unchanged; quit Action and retry.");
      }
    }
    installAppFromDmg(dmgPath);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }

  console.log(`Action ${version} installed to ${INSTALL_PATH}.`);
  console.log("Grant Accessibility and Screen Recording when Action prompts.");
  if (shouldLaunch) launchApp();
}

// ── Runtime ──────────────────────────────────────────────────────────

function launchApp(): void {
  const appPath = installedPath();
  if (!appPath) {
    console.error("Action is not installed. Run: lattices action install");
    process.exit(1);
  }
  // `open` on an installed bundle both launches and activates an existing instance.
  spawn("open", [appPath], { detached: true, stdio: "ignore" }).unref();
  console.log(isRunning() ? "Action focused." : "Action launched.");
}

async function status(json: boolean): Promise<void> {
  const appPath = installedPath();
  const version = appPath ? installedVersion(appPath) : null;
  const running = isRunning();
  const agent = await isActionAgentRunning();
  const checkout = findCheckout();

  if (json) {
    console.log(JSON.stringify({
      installed: appPath !== null,
      path: appPath,
      version,
      running,
      agentReachable: agent,
      agentUrl: "ws://127.0.0.1:4319",
      checkout,
      bundleId: ACTION_BUNDLE_ID,
    }, null, 2));
    return;
  }

  console.log("Action — native computer-use (lattices product)");
  console.log(`  installed   ${appPath ? `${version ?? "unknown version"} (${appPath})` : "no"}`);
  console.log(`  running     ${running ? "yes" : "no"}`);
  console.log(`  agent       ${agent ? "reachable (ws://127.0.0.1:4319)" : "not reachable"}`);
  console.log(`  checkout    ${checkout ?? "none (products/action not found)"}`);
  console.log("  capability  Run `lats action capabilities`; version alone does not prove layer support.");
  if (!appPath) {
    console.log(`\nInstall with: lattices action install`);
  }
}

async function callAgent(method: string | undefined, paramsJson: string | undefined): Promise<void> {
  if (!method) {
    console.log("Usage: lattices action call <method> [params-json]");
    console.log("\nExamples:");
    console.log("  lattices action call ping");
    console.log("  lattices action call status");
    console.log('  lattices action call capture.screenshotScreen \'{"path":"/tmp/s.png"}\'');
    return;
  }
  if (!(await isActionAgentRunning())) {
    console.error("Action agent is not reachable (ws://127.0.0.1:4319).");
    console.error("Start it with: lattices action launch");
    process.exit(1);
  }
  const params = paramsJson ? JSON.parse(paramsJson) : null;
  const res = await actionAgentCall(method, params, 30000);
  if (res.result) console.log(JSON.stringify(res.result, null, 2));
  if (!res.ok) {
    console.error(res.error ?? "Action agent call failed");
    process.exit(1);
  }
}

function forwardToCheckout(checkout: string, args: string[]): void {
  try {
    execFileSync("bun", ["--cwd", checkout, "action", ...args], { stdio: "inherit" });
  } catch {
    process.exit(1);
  }
}

function printUsage(): void {
  console.log(`lattices action — install and drive the Action product

Usage:
  lattices action              Show install/runtime status
  lattices action install      Download the latest action-v* release → /Applications
  lattices action update       Reinstall the latest release
  lattices action launch       Open Action.app (use --launch with install)
  lattices action quit         Quit Action.app
  lattices action call <m> [j] Raw Action agent call (ws://127.0.0.1:4319)
  lattices action mcp          Start the installed Action MCP server over stdio
  lattices action capabilities Read-only build fingerprints, native capability manifest, and MCP routing
  lattices action layer <verb> Private Action display lifecycle (requires runtime checkout/install)
  lattices action status --json
  lattices action <cmd> [args] Forward to the Action CLI (monorepo checkout)

Runtime lookup: ACTION_ROOT, a checkout, or the managed runtime install.
The published app-only installer does not include MCP orchestration.
Raw agent RPC stays available via \`lattices action call\`. Docs: ${ACTION_SITE_URL}
`);
}

// ── Entry ────────────────────────────────────────────────────────────

const rawArgs = process.argv.slice(2);
const first = rawArgs[0] && !rawArgs[0].startsWith("-") ? rawArgs[0] : undefined;
const rest = first ? rawArgs.slice(1) : rawArgs;
const wantsLaunch = rest.includes("--launch");
const wantsJson = rest.includes("--json");

switch (first) {
  case undefined:
    await status(wantsJson);
    break;
  case "install":
  case "update":
    await install(wantsLaunch);
    break;
  case "status":
    await status(wantsJson);
    break;
  case "launch":
  case "open":
  case "start":
    launchApp();
    break;
  case "quit":
  case "stop":
    console.log(quitApp() ? "Action launcher stopped; prepared workspaces remain available." : "Could not confirm Action launcher quit.");
    break;
  case "mcp": {
    const checkout = findCheckout();
    if (!checkout) {
      console.error("Action MCP runtime not installed. A native app alone does not include MCP orchestration; install a matching runtime bundle or set ACTION_ROOT.");
      process.exit(1);
    }
    try {
      execFileSync("bun", [resolve(checkout, "packages/mcp/src/index.ts")], {
        stdio: "inherit", env: { ...process.env, ACTION_ROOT: checkout },
      });
    } catch {
      process.exit(1);
    }
    break;
  }
  case "call":
    await callAgent(rest[0], rest[1]);
    break;
  case "help":
  case "-h":
  case "--help":
    printUsage();
    break;
  default: {
    const checkout = findCheckout();
    if (checkout) {
      forwardToCheckout(checkout, rawArgs);
    } else {
      console.error(`Unknown action command: ${first}`);
      console.error("No products/action checkout found — run `lattices action help`.");
      process.exit(1);
    }
  }
}
