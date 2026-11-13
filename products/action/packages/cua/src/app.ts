/**
 * Action.app lifecycle for the `action` CLI: install from the latest action-v*
 * release, launch, quit, status, raw agent calls, and forwarding to a runtime
 * checkout for commands this package does not own (layer, capabilities, …).
 */
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createWriteStream, existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { get } from "node:https";
import type { IncomingMessage } from "node:http";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { actionAgentCall, agentSocketPath, isActionAgentRunning, type ActionAgentResult } from "./agent.js";

// The numeric repository identity survives owner/name transfers.
const RELEASES_API = "https://api.github.com/repositories/1171006654/releases?per_page=30";
const TAG_PREFIX = "action-v";
const DMG_ASSET = "Action.dmg";
const APP_NAME = "Action.app";
export const BUNDLE_ID = "dev.lattices.Action";
const INSTALL_PATH = `/Applications/${APP_NAME}`;
export const SITE_URL = "https://lattices.dev/action";

export type AppStatus = {
  installed: boolean;
  path: string | null;
  version: string | null;
  running: boolean;
  agentReachable: boolean;
  agentSocket: string;
  bundleId: string;
  checkout: string | null;
};

export type InstallResult = { version: string; path: string; changed: boolean };

/** What the CLI needs from the machine; tests replace it. */
export type AppControl = {
  status(): Promise<AppStatus>;
  install(log: (line: string) => void): Promise<InstallResult>;
  /** Opens Action.app; reports whether it was already running. */
  launch(): { path: string; wasRunning: boolean };
  quit(): Promise<boolean>;
  call(method: string, params: Record<string, unknown> | null, timeoutMs: number): Promise<ActionAgentResult>;
  /** Runs `action <args>` in a runtime checkout; undefined when there is none. */
  forward(args: string[]): number | undefined;
};

type Release = { tag_name: string; draft: boolean; prerelease: boolean; assets: Array<{ name: string; browser_download_url: string }> };

function isRunning(): boolean {
  try { execFileSync("pgrep", ["-x", "Action"], { stdio: "pipe" }); return true; } catch { return false; }
}

export function installedPath(): string | null {
  if (process.env.ACTION_APP && existsSync(process.env.ACTION_APP)) return process.env.ACTION_APP;
  for (const path of [INSTALL_PATH, join(homedir(), "Applications", APP_NAME)]) if (existsSync(path)) return path;
  try {
    const found = execFileSync("mdfind", [`kMDItemCFBundleIdentifier == '${BUNDLE_ID}'`], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim().split("\n")[0];
    if (found && existsSync(found)) return found;
  } catch { /* Spotlight unavailable */ }
  return null;
}

function installedVersion(appPath: string): string | null {
  try {
    return execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString", join(appPath, "Contents/Info.plist")], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim() || null;
  } catch { return null; }
}

/** products/action, from ACTION_ROOT, this package's own checkout, the managed runtime, or the cwd's repository. */
export function findCheckout(): string | null {
  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [process.env.ACTION_ROOT, resolve(here, "../../.."), join(homedir(), "Library/Application Support/Lattices/runtime/current/products/action")];
  try {
    const top = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    if (top) candidates.push(resolve(top, "products/action"));
  } catch { /* not in a repository */ }
  return candidates.find((dir): dir is string => !!dir && existsSync(join(dir, "packages/cli/src/main.ts"))) ?? null;
}

function httpsGet(url: string, redirects = 5): Promise<IncomingMessage> {
  return new Promise((resolve, reject) => {
    get(url, { headers: { "User-Agent": "lattices-action", Accept: "application/vnd.github+json" } }, (res) => {
      const status = res.statusCode ?? 0;
      if (status >= 300 && status < 400 && res.headers.location && redirects > 0) {
        res.resume();
        httpsGet(new URL(res.headers.location, url).toString(), redirects - 1).then(resolve, reject);
        return;
      }
      if (status !== 200) { res.resume(); reject(new Error(`HTTP ${status} from ${new URL(url).host}`)); return; }
      resolve(res);
    }).on("error", reject);
  });
}

async function latestRelease(): Promise<Release | null> {
  const res = await httpsGet(RELEASES_API);
  const chunks: Buffer[] = [];
  for await (const chunk of res) chunks.push(chunk as Buffer);
  const releases = JSON.parse(Buffer.concat(chunks).toString()) as Release[];
  return releases.find((r) => !r.draft && !r.prerelease && r.tag_name.startsWith(TAG_PREFIX)) ?? null;
}

async function download(url: string, destination: string): Promise<void> {
  const res = await httpsGet(url);
  await new Promise<void>((resolve, reject) => {
    const out = createWriteStream(destination);
    res.pipe(out);
    out.on("finish", resolve);
    out.on("error", reject);
  });
}

function copyFromDmg(dmg: string): void {
  const mount = mkdtempSync(join(tmpdir(), "action-mount-"));
  try {
    execFileSync("hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount, dmg], { stdio: "pipe" });
    const app = join(mount, APP_NAME);
    if (!existsSync(app)) throw new Error(`${APP_NAME} is not in the disk image.`);
    rmSync(INSTALL_PATH, { recursive: true, force: true });
    execFileSync("cp", ["-R", app, INSTALL_PATH]);
  } finally {
    try { execFileSync("hdiutil", ["detach", mount, "-quiet"], { stdio: "pipe" }); } catch { /* already detached */ }
    rmSync(mount, { recursive: true, force: true });
  }
}

/** Ask the app itself to quit: it tells launchers from persistent display owners, which pgrep cannot. */
async function quitApp(): Promise<boolean> {
  const app = installedPath();
  if (!app) return false;
  const directory = mkdtempSync(join(tmpdir(), "action-quit-"));
  const reply = join(directory, "reply.json");
  try {
    execFileSync("/usr/bin/open", ["-n", "-g", app, "--args", "quit-app", "--reply-file", reply], { stdio: "ignore" });
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      if (existsSync(reply)) {
        try { return JSON.parse(readFileSync(reply, "utf8")).status === "quit"; } catch { /* still writing */ }
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    return false;
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

export const systemApp: AppControl = {
  async status() {
    const path = installedPath();
    return {
      installed: path !== null,
      path,
      version: path ? installedVersion(path) : null,
      running: isRunning(),
      agentReachable: await isActionAgentRunning(),
      agentSocket: agentSocketPath(),
      bundleId: BUNDLE_ID,
      checkout: findCheckout(),
    };
  },
  async install(log) {
    log("Finding the latest Action release…");
    const release = await latestRelease();
    if (!release) throw new Error(`No published Action release (${TAG_PREFIX}* tags). Download it from ${SITE_URL}.`);
    const asset = release.assets.find((a) => a.name === DMG_ASSET);
    if (!asset) throw new Error(`Release ${release.tag_name} has no ${DMG_ASSET}.`);
    const version = release.tag_name.slice(TAG_PREFIX.length);
    const existing = installedPath();
    if (existing && installedVersion(existing) === version) return { version, path: existing, changed: false };
    log(`Downloading Action ${version}…`);
    const directory = mkdtempSync(join(tmpdir(), "action-download-"));
    try {
      const dmg = join(directory, DMG_ASSET);
      await download(asset.browser_download_url, dmg);
      if (isRunning()) {
        log("Quitting the running Action…");
        if (!await quitApp()) throw new Error("Action did not quit, so the installed app is unchanged. Quit Action and retry.");
      }
      copyFromDmg(dmg);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
    return { version, path: INSTALL_PATH, changed: true };
  },
  launch() {
    const path = installedPath();
    if (!path) throw new Error("Action is not installed. Run: action install");
    const wasRunning = isRunning();
    spawn("/usr/bin/open", [path], { detached: true, stdio: "ignore" }).unref();
    return { path, wasRunning };
  },
  quit: quitApp,
  call: actionAgentCall,
  forward(args) {
    const checkout = findCheckout();
    if (!checkout) return undefined;
    const run = spawnSync("bun", [join(checkout, "packages/cli/src/main.ts"), ...args], { cwd: checkout, stdio: "inherit", env: { ...process.env, ACTION_ROOT: checkout } });
    return run.status ?? 1;
  },
};
