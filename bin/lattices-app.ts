#!/usr/bin/env bun

import { execFileSync, execSync, spawnSync, spawn } from "node:child_process";
import { cpSync, existsSync, mkdirSync, chmodSync, createWriteStream, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { get } from "node:https";
import type { IncomingMessage } from "node:http";
import { resolveBuildEnv } from "./lattices-build-env";
import { embedHelpers, signHelpers } from "./embedded-helpers";
import { readBuildMetadata } from "./lattices-build-metadata";

const __dirname = import.meta.dir;
const appDir = resolve(__dirname, "../apps/mac");
const cliRoot = resolve(__dirname, "..");
const bundlePath = resolve(appDir, "Lattices.app");
const binaryDir = resolve(bundlePath, "Contents/MacOS");
const binaryPath = resolve(binaryDir, "Lattices");
const entitlementsPath = resolve(__dirname, "../apps/mac/Lattices.entitlements");
const resourcesDir = resolve(bundlePath, "Contents/Resources");
const iconPath = resolve(__dirname, "../assets/AppIcon.icns");
const tapSoundPath = resolve(__dirname, "../apps/mac/Resources/tap.wav");
const deckBuilderResourcesPath = resolve(__dirname, "../apps/mac/Resources/DeckBuilder");
const launchAgentLabel = "dev.lattices.app.login";
const launchAgentPath = resolve(homedir(), "Library/LaunchAgents", `${launchAgentLabel}.plist`);
const launchAgentLogPath = resolve(homedir(), ".lattices", "lattices-launchagent.log");

const REPO = "arach/lattices";
const RELEASE_APP_ASSET_NAMES = ["Lattices.dmg"];
const RELEASE_BINARY_ASSET_NAMES = ["Lattices-macos-arm64", "LatticeApp-macos-arm64"];
type ReleaseAsset = { name: string; browser_download_url: string };
const selfScriptPath = resolve(__dirname, "lattices-app.ts");
const CAPS_LOCK_HID_USAGE = 0x700000039;
const F18_HID_USAGE = 0x70000006D;

// ── Helpers ──────────────────────────────────────────────────────────

function isRunning(): boolean {
  try {
    execSync("pgrep -x Lattices", { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

type RunningProcess = { pid: string; command: string };

function runningLatticesProcesses(): RunningProcess[] {
  let pids: string[];
  try {
    pids = execFileSync("pgrep", ["-x", "Lattices"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim().split(/\s+/).filter(Boolean);
  } catch {
    return [];
  }

  const processes: RunningProcess[] = [];
  for (const pid of pids) {
    try {
      const command = execFileSync("ps", ["-p", pid, "-o", "command="], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
      if (command) processes.push({ pid, command });
    } catch {}
  }
  return processes;
}

function runningBundleProcesses(targetBundlePath = bundlePath): RunningProcess[] {
  const executable = resolve(targetBundlePath, "Contents/MacOS/Lattices");
  return runningLatticesProcesses().filter(({ command }) =>
    command === executable || command.startsWith(`${executable} `)
  );
}

function requireBundleNotRunningForBuild(): void {
  const running = runningBundleProcesses();
  if (!running.length) return;

  console.error("Refusing to rebuild Lattices.app while that bundle is running.");
  console.error("Rewriting or re-signing a live Mach-O can make macOS kill it later with Code Signature Invalid.");
  console.error(`Running PID(s): ${running.map((proc) => proc.pid).join(", ")}`);
  console.error("Use `lats app restart` to quit, rebuild, and relaunch, or run `lats app quit` before `lats app build`.");
  process.exit(1);
}

function sleep(ms: number): void {
  execFileSync("/bin/sleep", [(ms / 1000).toString()], { stdio: "ignore" });
}

function waitForExit(timeoutMs: number): boolean {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!isRunning()) return true;
    sleep(100);
  }
  return !isRunning();
}

type HIDKeyboardMapping = { src: number; dst: number };

function hasOwnedCapsLockTransportMapping(): boolean {
  try {
    return execFileSync(
      "/usr/bin/defaults",
      ["read", "dev.lattices.app", "keyboardRemaps.capsLockHIDTransportOwned"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
    ).trim() === "1";
  } catch {
    return false;
  }
}

function readHIDKeyboardMappings(): HIDKeyboardMapping[] {
  try {
    const output = execFileSync(
      "/usr/bin/hidutil",
      ["property", "--get", "UserKeyMapping"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
    );
    return Array.from(output.matchAll(/HIDKeyboardModifierMappingDst\s*=\s*(\d+);\s*HIDKeyboardModifierMappingSrc\s*=\s*(\d+);/g))
      .map((match) => ({ dst: Number(match[1]), src: Number(match[2]) }));
  } catch {
    return [];
  }
}

function writeHIDKeyboardMappings(mappings: HIDKeyboardMapping[]): void {
  const pairs = mappings.map((mapping) => ({
    HIDKeyboardModifierMappingSrc: mapping.src,
    HIDKeyboardModifierMappingDst: mapping.dst,
  }));
  execFileSync(
    "/usr/bin/hidutil",
    ["property", "--set", JSON.stringify({ UserKeyMapping: pairs })],
    { stdio: "ignore" }
  );
}

function clearOwnedCapsLockTransportMapping(): void {
  if (!hasOwnedCapsLockTransportMapping()) return;

  const mappings = readHIDKeyboardMappings();
  const filtered = mappings.filter((mapping) => (
    mapping.src !== CAPS_LOCK_HID_USAGE || mapping.dst !== F18_HID_USAGE
  ));

  if (filtered.length !== mappings.length) {
    try {
      writeHIDKeyboardMappings(filtered);
    } catch {
      console.log("Warning: failed to clear Caps Lock HID transport mapping.");
      return;
    }
  }

  try {
    execFileSync("/usr/bin/defaults", ["delete", "dev.lattices.app", "keyboardRemaps.capsLockHIDTransportOwned"], { stdio: "ignore" });
  } catch {}
  try {
    execFileSync("/usr/bin/defaults", ["delete", "dev.lattices.app", "keyboardRemaps.capsLockHIDTransportOriginalMappings"], { stdio: "ignore" });
  } catch {}
}

function quit(): boolean {
  if (!isRunning()) {
    clearOwnedCapsLockTransportMapping();
    return false;
  }

  try {
    execFileSync(
      "/usr/bin/osascript",
      ["-e", 'tell application id "dev.lattices.app" to quit'],
      { stdio: "ignore" }
    );
  } catch {}

  if (!waitForExit(2_000)) {
    try { execSync("pkill -x Lattices", { stdio: "pipe" }); } catch {}
    waitForExit(1_000);
  }

  if (isRunning()) {
    try { execSync("pkill -9 -x Lattices", { stdio: "pipe" }); } catch {}
    waitForExit(500);
  }

  clearOwnedCapsLockTransportMapping();
  return !isRunning();
}

function hasSwift(): boolean {
  try {
    execSync("which swift", { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function packageVersion(): string {
  try {
    const pkg = JSON.parse(readFileSync(resolve(__dirname, "../package.json"), "utf8"));
    return typeof pkg.version === "string" ? pkg.version : "0.1.0";
  } catch {
    return "0.1.0";
  }
}

function xmlEscape(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function launch(extraArgs: string[] = []): void {
  if (isRunning()) {
    console.log("lattices app is already running.");
    return;
  }
  const args = [bundlePath];
  const appArgs = ["--lattices-cli-root", cliRoot, ...extraArgs];
  if (appArgs.length) args.push("--args", ...appArgs);
  spawn("open", args, { detached: true, stdio: "ignore" }).unref();
  console.log("lattices app launched.");
}

function launchctlDomain(): string {
  if (typeof process.getuid === "function") return `gui/${process.getuid()}`;
  const uid = execFileSync("/usr/bin/id", ["-u"], { encoding: "utf8" }).trim();
  return `gui/${uid}`;
}

function plistString(value: string, indent = "        "): string {
  return `${indent}<string>${xmlEscape(value)}</string>`;
}

function writeLaunchAgent(extraArgs: string[] = []): void {
  mkdirSync(resolve(homedir(), "Library/LaunchAgents"), { recursive: true });
  mkdirSync(resolve(homedir(), ".lattices"), { recursive: true });

  const args = [
    "/usr/bin/open",
    bundlePath,
    "--args",
    "--lattices-cli-root",
    cliRoot,
    ...extraArgs,
  ];
  const plistArgs = args.map((arg) => plistString(arg)).join("\n");
  const escapedLogPath = xmlEscape(launchAgentLogPath);
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${xmlEscape(launchAgentLabel)}</string>
    <key>ProgramArguments</key>
    <array>
${plistArgs}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>${escapedLogPath}</string>
    <key>StandardErrorPath</key>
    <string>${escapedLogPath}</string>
</dict>
</plist>
`;
  writeFileSync(launchAgentPath, plist);
}

function isLaunchAgentLoaded(): boolean {
  try {
    execFileSync("/bin/launchctl", ["print", `${launchctlDomain()}/${launchAgentLabel}`], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function unloadLaunchAgent(): void {
  const domain = launchctlDomain();
  try {
    execFileSync("/bin/launchctl", ["bootout", domain, launchAgentPath], { stdio: "ignore" });
  } catch {}
  try {
    execFileSync("/bin/launchctl", ["bootout", `${domain}/${launchAgentLabel}`], { stdio: "ignore" });
  } catch {}
}

function loadLaunchAgent(): void {
  const domain = launchctlDomain();
  unloadLaunchAgent();
  execFileSync("/bin/launchctl", ["bootstrap", domain, launchAgentPath], { stdio: "inherit" });
  try {
    execFileSync("/bin/launchctl", ["enable", `${domain}/${launchAgentLabel}`], { stdio: "ignore" });
  } catch {}
}

function filterStartupArgs(args: string[]): { extraArgs: string[]; shouldLaunch: boolean } {
  return {
    extraArgs: args.filter((arg) => arg !== "--no-launch"),
    shouldLaunch: !args.includes("--no-launch"),
  };
}

async function installLaunchAgent(args: string[] = []): Promise<void> {
  const { extraArgs, shouldLaunch } = filterStartupArgs(args);
  await ensureBinary();
  writeLaunchAgent(extraArgs);
  loadLaunchAgent();
  console.log(`lattices app will open at login.`);
  console.log(`LaunchAgent: ${launchAgentPath}`);
  if (shouldLaunch) launch(extraArgs);
}

function uninstallLaunchAgent(): void {
  unloadLaunchAgent();
  if (existsSync(launchAgentPath)) {
    rmSync(launchAgentPath, { force: true });
  }
  console.log("lattices app startup registration removed.");
}

function printAppStatus(): void {
  console.log(`App running: ${isRunning() ? "yes" : "no"}`);
  console.log(`Startup installed: ${existsSync(launchAgentPath) ? "yes" : "no"}`);
  console.log(`LaunchAgent loaded: ${isLaunchAgentLoaded() ? "yes" : "no"}`);
  console.log(`LaunchAgent: ${launchAgentPath}`);
}

function relaunchIfNeeded(shouldLaunch: boolean, extraArgs: string[] = []): void {
  if (!shouldLaunch) {
    console.log("App updated. Launch with: lats app");
    return;
  }
  launch(extraArgs);
}

function resolveSigningIdentity(): string | null {
  if (process.env.LATTICES_SIGN_IDENTITY) return process.env.LATTICES_SIGN_IDENTITY;
  try {
    const identities = execSync("security find-identity -v -p codesigning", { stdio: "pipe" }).toString();
    return identities.match(/^\s*\d+\)\s+([A-F0-9]{40})\s+"Developer ID Application:[^"]+"/m)?.[1]
        || identities.match(/^\s*\d+\)\s+([A-F0-9]{40})\s+"Apple Development:[^"]+"/m)?.[1]
        || null;
  } catch {
    return null;
  }
}

function bundleTeamIdentifier(): string | null {
  try {
    // codesign writes display metadata to stderr, including on success.
    const result = spawnSync("codesign", ["-dv", bundlePath], { encoding: "utf8" });
    if (result.error || result.status !== 0) return null;
    const output = result.stdout + result.stderr;
    const match = output.match(/TeamIdentifier=(.+)/);
    const team = match?.[1]?.trim();
    return team && team !== "not set" ? team : null;
  } catch {
    return null;
  }
}

function runCodesign(args: string[]): void {
  try {
    execFileSync("codesign", args, { stdio: "pipe" });
  } catch (error) {
    const stderr = (error as { stderr?: Buffer | string }).stderr;
    const detail = stderr ? `\n${String(stderr).trim()}` : "";
    throw new Error(`codesign ${args.join(" ")}${detail}`);
  }
}

function signBundle(requireDeveloperID = false): void {
  const identity = resolveSigningIdentity();
  const entitlements = existsSync(entitlementsPath) ? entitlementsPath : null;
  const tempBinaryPath = `${binaryPath}.cstemp`;

  try {
    if (existsSync(tempBinaryPath)) rmSync(tempBinaryPath, { force: true });
  } catch {}

  const sign = (signer: string, label: string) => {
    // Inside out: embedded helpers (Contents/Helpers) first, under the same signer.
    signHelpers(bundlePath, signer, { timestamp: requireDeveloperID });
    // Sign the Mach-O first, then the bundle — more reliable than --deep and
    // keeps a stable TeamIdentifier so macOS TCC grants survive rebuilds.
    const binaryArgs = ["--force", "--options", "runtime", "--sign", signer];
    if (requireDeveloperID) binaryArgs.push("--timestamp");
    if (entitlements) binaryArgs.push("--entitlements", entitlements);
    binaryArgs.push(binaryPath);
    runCodesign(binaryArgs);

    const bundleArgs = ["--force", "--options", "runtime", "--sign", signer];
    if (requireDeveloperID) bundleArgs.push("--timestamp");
    if (entitlements) bundleArgs.push("--entitlements", entitlements);
    bundleArgs.push("--identifier", "dev.lattices.app", bundlePath);
    runCodesign(bundleArgs);
    runCodesign(["--verify", "--deep", "--strict", bundlePath]);
    if (requireDeveloperID) {
      const details = spawnSync("codesign", ["-dv", "--verbose=4", bundlePath], { encoding: "utf8" });
      if (details.status !== 0 || !/^Authority=Developer ID Application:/m.test(details.stdout + details.stderr)) {
        throw new Error("Release builds require a Developer ID Application signature");
      }
    }

    const team = bundleTeamIdentifier();
    if (team) {
      console.log(`Signed (${label}) — TeamIdentifier=${team}`);
      return;
    }
    if (label === "ad-hoc") return;
    throw new Error(`codesign reported no TeamIdentifier after ${label} signing`);
  };

  if (identity) {
    console.log(`Signing with: ${identity}`);
    try {
      sign(identity, "developer");
      return;
    } catch (error) {
      if (requireDeveloperID) throw error;
      console.log(`Warning: signing with '${identity}' failed — ${(error as Error).message}`);
      console.log("Warning: falling back to ad-hoc. Privacy permissions will not persist across rebuilds.");
    }
  } else {
    if (requireDeveloperID) throw new Error("Release builds require a Developer ID Application signing identity");
    console.log("Warning: no local signing identity found — falling back to ad-hoc.");
    console.log("Warning: grant Accessibility/Screen Recording again after each rebuild, or install a signing cert.");
  }

  sign("-", "ad-hoc");

  try {
    if (existsSync(tempBinaryPath)) rmSync(tempBinaryPath, { force: true });
  } catch {}
}

type BundleBuildMetadata = {
  channel?: "dev" | "release";
  track?: string;
  revision?: string;
  timestamp?: string;
  sourceDigest?: string;
};

function buildMetadataPlist(metadata: BundleBuildMetadata): string {
  if (!metadata.channel) return "";

  const track = metadata.track ?? "latest";
  const current = metadata.revision && metadata.sourceDigest ? metadata : readBuildMetadata(cliRoot);
  const revision = current.revision!;
  const timestamp = metadata.timestamp ?? new Date().toISOString();

  return `    <key>LatticesBuildChannel</key>
    <string>${metadata.channel}</string>
    <key>LatticesBuildTrack</key>
    <string>${xmlEscape(track)}</string>
    <key>LatticesBuildRevision</key>
    <string>${xmlEscape(revision)}</string>
    <key>LatticesBuildTimestamp</key>
    <string>${xmlEscape(timestamp)}</string>
    <key>LatticesBuildSourceDigest</key>
    <string>${xmlEscape(current.sourceDigest!)}</string>
`;
}

function writeInfoPlist(metadata: BundleBuildMetadata = {}): void {
  mkdirSync(resolve(bundlePath, "Contents"), { recursive: true });
  const version = packageVersion();
  const buildMetadata = buildMetadataPlist(metadata);
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.lattices.app</string>
    <key>CFBundleName</key>
    <string>Lattices</string>
    <key>CFBundleDisplayName</key>
    <string>Lattices</string>
    <key>CFBundleExecutable</key>
    <string>Lattices</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.lattices.app</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>lattices</string>
            </array>
        </dict>
    </array>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
${buildMetadata}    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Lattices uses the microphone for Hudson Voice dictation and voice commands.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
</dict>
</plist>
`;
  writeFileSync(resolve(bundlePath, "Contents/Info.plist"), plist);
}

function syncBundleResources(): void {
  mkdirSync(resourcesDir, { recursive: true });
  rmSync(resolve(binaryDir, "CompanionInstaller"), { force: true });
  execFileSync(process.execPath, [resolve(cliRoot, "bin/build-companion-installer.ts"), resolve(resourcesDir, "companion-installer.js")], { stdio: "inherit" });
  if (existsSync(iconPath)) {
    execFileSync("cp", [iconPath, resolve(resourcesDir, "AppIcon.icns")]);
  }
  if (existsSync(tapSoundPath)) {
    execFileSync("cp", [tapSoundPath, resolve(resourcesDir, "tap.wav")]);
  }
  if (existsSync(deckBuilderResourcesPath)) {
    const bundledDeckBuilderPath = resolve(resourcesDir, "DeckBuilder");
    rmSync(bundledDeckBuilderPath, { recursive: true, force: true });
    cpSync(deckBuilderResourcesPath, bundledDeckBuilderPath, { recursive: true });
  }
  // SwiftPM resource bundles resolve from Contents/Resources in a packaged
  // app; mirror the release layout so dev builds exercise the same path.
  const buildOutputDir = resolve(appDir, ".build/release");
  if (existsSync(buildOutputDir)) {
    for (const entry of readdirSync(buildOutputDir)) {
      if (!entry.endsWith(".bundle")) continue;
      const target = resolve(resourcesDir, entry);
      rmSync(target, { recursive: true, force: true });
      cpSync(resolve(buildOutputDir, entry), target, { recursive: true });
    }
  }
  // Bundle the assistant knowledge base so the in-app chat assistant can load it
  // in shipped builds (dev builds fall back to the repo docs/ path).
  const assistantDoc = resolve(cliRoot, "docs/assistant-knowledge.md");
  if (existsSync(assistantDoc)) {
    const docsDir = resolve(resourcesDir, "docs");
    mkdirSync(docsDir, { recursive: true });
    execFileSync("cp", [assistantDoc, resolve(docsDir, "assistant-knowledge.md")]);
  }
}

// ── Build from source (current arch only) ────────────────────────────

function buildFromSource(): boolean {
  console.log("Building lattices app from source...");
  const channel = process.env.LATTICES_BUILD_CHANNEL ?? "dev";
  if (channel !== "dev" && channel !== "release") throw new Error("LATTICES_BUILD_CHANNEL must be dev or release");
  const buildEnv = resolveBuildEnv();
  const metadata = readBuildMetadata(cliRoot, buildEnv);
  try {
    execSync("swift build -c release", {
      cwd: appDir,
      stdio: "inherit",
      // Build features are declared in apps/mac/build.json and resolved to the
      // HUDSONKIT_WITH_* env HudsonKit gates on — one source of truth across
      // every build entrypoint (see bin/lattices-build-env.ts).
      env: { ...process.env, ...buildEnv },
    });
  } catch {
    return false;
  }

  const builtPath = resolve(appDir, ".build/release/Lattices");
  if (!existsSync(builtPath)) return false;
  const currentMetadata = readBuildMetadata(cliRoot, buildEnv);
  if (currentMetadata.sourceDigest !== metadata.sourceDigest || currentMetadata.revision !== metadata.revision) {
    console.error("Build inputs changed during compilation; rebuild from a stable checkout.");
    return false;
  }

  mkdirSync(binaryDir, { recursive: true });
  execFileSync("cp", [builtPath, binaryPath]);
  writeInfoPlist({ channel, ...metadata });
  syncBundleResources();
  try {
    embedHelpers(bundlePath);
  } catch (error) {
    console.error(`Embedding helpers failed: ${(error as Error).message}`);
    console.error("Set LATTICES_SKIP_HELPERS=1 to build without them.");
    return false;
  }

  // Re-sign the bundle so macOS TCC recognizes a stable identity across rebuilds.
  // Prefer a real local signing identity; only fall back to ad-hoc when necessary.
  try {
    signBundle(channel === "release");
  } catch (error) {
    console.error(`Code signing failed: ${(error as Error).message}`);
    return false;
  }
  // Update bundle timestamp so Finder shows the correct modified date
  try { execFileSync("touch", [bundlePath], { stdio: "pipe" }); } catch {}
  console.log("Build complete.");
  return true;
}

// ── Download from GitHub releases ────────────────────────────────────

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

async function downloadToFile(url: string, destination: string): Promise<void> {
  const res = await httpsGet(url);
  const ws = createWriteStream(destination);
  await new Promise<void>((resolve, reject) => {
    res.pipe(ws);
    ws.on("finish", resolve);
    ws.on("error", reject);
  });
}

function installBundleFromDmg(dmgPath: string): void {
  const mountPoint = mkdtempSync(join(tmpdir(), "lattices-mount-"));
  try {
    execFileSync("hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint, dmgPath], { stdio: "pipe" });
    const mountedBundle = resolve(mountPoint, "Lattices.app");
    if (!existsSync(mountedBundle)) {
      throw new Error("Lattices.app not found in mounted disk image");
    }
    rmSync(bundlePath, { recursive: true, force: true });
    execFileSync("cp", ["-R", mountedBundle, bundlePath]);
  } finally {
    try {
      execFileSync("hdiutil", ["detach", mountPoint, "-quiet"], { stdio: "pipe" });
    } catch {}
    rmSync(mountPoint, { recursive: true, force: true });
  }
}

async function download(): Promise<boolean> {
  console.log("Downloading pre-built lattices app...");

  try {
    const apiUrl = `https://api.github.com/repos/${REPO}/releases/latest`;
    const apiRes = await httpsGet(apiUrl);
    const chunks: Buffer[] = [];
    for await (const chunk of apiRes) chunks.push(chunk as Buffer);
    const release = JSON.parse(Buffer.concat(chunks).toString());

    const assets: ReleaseAsset[] = Array.isArray(release.assets) ? release.assets : [];
    const appAsset = assets.find((a) =>
      RELEASE_APP_ASSET_NAMES.includes(a.name) || (a.name.endsWith(".dmg") && a.name.startsWith("Lattices"))
    );
    if (appAsset) {
      const tempDir = mkdtempSync(join(tmpdir(), "lattices-download-"));
      const dmgPath = resolve(tempDir, appAsset.name);
      try {
        await downloadToFile(appAsset.browser_download_url, dmgPath);
        installBundleFromDmg(dmgPath);
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
      }
      console.log("Download complete.");
      return true;
    }

    const binaryAsset = assets.find((a) => RELEASE_BINARY_ASSET_NAMES.includes(a.name));
    if (!binaryAsset) throw new Error("App bundle not found in release assets");

    mkdirSync(binaryDir, { recursive: true });
    await downloadToFile(binaryAsset.browser_download_url, binaryPath);
    chmodSync(binaryPath, 0o755);
    writeInfoPlist();
    syncBundleResources();
    console.log("Download complete.");
    return true;
  } catch (e) {
    console.log(`Download failed: ${(e as Error).message}`);
    return false;
  }
}

// ── Commands ─────────────────────────────────────────────────────────

async function ensureBinary(): Promise<void> {
  if (existsSync(binaryPath)) return;

  const downloaded = await download();
  if (downloaded) return;

  console.error(
    "Could not find a bundled lattices app or download one.\n" +
    "Options:\n" +
    "  \u2022 Reinstall or update @arach/lattices\n" +
    "  \u2022 Developers can build from source with: lattices-app build\n" +
    "  \u2022 Download manually from:   https://github.com/" + REPO + "/releases"
  );
  process.exit(1);
}

function spawnDetachedUpdateWorker(extraArgs: string[] = [], shouldLaunch = false): void {
  const workerArgs = [
    selfScriptPath,
    "update",
    "--worker",
    ...(shouldLaunch ? ["--launch"] : []),
    ...extraArgs,
  ];
  const child = spawn(process.execPath, workerArgs, {
    cwd: cliRoot,
    detached: true,
    stdio: "ignore",
  });
  child.unref();
}

async function updateApp(extraArgs: string[] = [], shouldLaunch = false): Promise<void> {
  const wasRunning = isRunning();
  if (wasRunning) {
    quit();
  }

  const downloaded = await download();
  if (!downloaded) {
    console.error("Update failed.");
    if (wasRunning || shouldLaunch || extraArgs.length > 0) {
      launch(extraArgs);
    }
    process.exit(1);
  }

  relaunchIfNeeded(shouldLaunch || wasRunning || extraArgs.length > 0, extraArgs);
}

// ── Package upgrade (CLI + bundled app) ──────────────────────────────

const NPM_PACKAGE = "@arach/lattices";

function isSourceCheckout(): boolean {
  return existsSync(resolve(cliRoot, ".git")) || existsSync(resolve(appDir, "Package.swift"));
}

// Reinstall with whichever package manager owns this global install, so the
// package lands back at the same path the LaunchAgent points at.
function globalInstallCommand(): [string, string[]] {
  const spec = `${NPM_PACKAGE}@latest`;
  if (cliRoot.includes("/.bun/install/global/")) return ["bun", ["add", "-g", spec]];
  if (cliRoot.includes("/pnpm/")) return ["pnpm", ["add", "-g", spec]];
  return ["npm", ["install", "-g", spec]];
}

async function latestPublishedVersion(): Promise<string | null> {
  try {
    const res = await httpsGet(`https://registry.npmjs.org/${NPM_PACKAGE.replace("/", "%2f")}/latest`);
    const chunks: Buffer[] = [];
    for await (const chunk of res) chunks.push(chunk as Buffer);
    const version = JSON.parse(Buffer.concat(chunks).toString()).version;
    return typeof version === "string" ? version : null;
  } catch {
    return null;
  }
}

function runFreshHelper(args: string[]): void {
  // Run the newly installed helper, not this process's stale in-memory copy.
  try {
    execFileSync(process.execPath, [selfScriptPath, ...args], { stdio: "inherit" });
  } catch {}
}

async function upgradePackage(force: boolean): Promise<void> {
  if (isSourceCheckout()) {
    console.log(`This lattices runs from a source checkout (${cliRoot}).`);
    console.log("Update it with: git pull && lats app restart");
    return;
  }

  const current = packageVersion();
  const latest = await latestPublishedVersion();
  if (latest && latest === current && !force) {
    console.log(`lattices ${current} is up to date.`);
    return;
  }

  const wasRunning = isRunning();
  const startupInstalled = existsSync(launchAgentPath);
  if (wasRunning) quit();

  const [pm, pmArgs] = globalInstallCommand();
  console.log(`Updating lattices ${current} → ${latest ?? "latest"}  (${pm} ${pmArgs.join(" ")})`);
  try {
    execFileSync(pm, pmArgs, { stdio: "inherit" });
  } catch {
    console.error("Update failed.");
    if (pm === "npm") console.error("If npm needs elevated permissions, fix the global prefix rather than using sudo.");
    if (wasRunning) launch();
    process.exit(1);
  }

  if (!existsSync(selfScriptPath)) {
    console.log(`lattices updated, but the install moved away from ${cliRoot}.`);
    console.log("Run `lats app install` to re-register startup and relaunch.");
    return;
  }

  // Rewrite the LaunchAgent so it tracks the new install; relaunch if it was up.
  if (startupInstalled) runFreshHelper(["install", ...(wasRunning ? [] : ["--no-launch"])]);
  else if (wasRunning) runFreshHelper(["launch"]);

  console.log(`lattices ${packageVersion()} installed.`);
}

const rawArgs = process.argv.slice(2);
const firstArg = rawArgs[0];
const cmd = firstArg && !firstArg.startsWith("-") ? firstArg : "launch";
const flags = firstArg && !firstArg.startsWith("-") ? rawArgs.slice(1) : rawArgs;
const launchFlags: string[] = [];
if (flags.includes("--diagnostics") || flags.includes("-d")) launchFlags.push("--diagnostics");
if (flags.includes("--screen-map") || flags.includes("-m")) launchFlags.push("--screen-map");
const startupFlags = [...launchFlags, ...(flags.includes("--no-launch") ? ["--no-launch"] : [])];
const shouldLaunchAfterUpdate = flags.includes("--launch") || launchFlags.length > 0;
const shouldDetachUpdate = flags.includes("--detach");
const isUpdateWorker = flags.includes("--worker");
const loginAction = flags.find((flag) => !flag.startsWith("-")) ?? "status";

if (cmd === "build") {
  requireBundleNotRunningForBuild();
  if (!hasSwift()) {
    console.error("Swift is required. Install with: xcode-select --install");
    process.exit(1);
  }
  if (!buildFromSource()) {
    console.error("Build failed.");
    process.exit(1);
  }
} else if (cmd === "quit") {
  if (quit()) {
    console.log("lattices app stopped.");
  } else {
    console.log("lattices app is not running.");
  }
} else if (cmd === "restart") {
  // Quit → rebuild → relaunch
  quit();
  if (!hasSwift()) {
    console.error("Swift is required. Install with: xcode-select --install");
    process.exit(1);
  }
  if (!buildFromSource()) {
    console.error("Build failed.");
    process.exit(1);
  }
  launch(launchFlags);
} else if (cmd === "install") {
  await installLaunchAgent(startupFlags);
} else if (cmd === "uninstall") {
  uninstallLaunchAgent();
} else if (cmd === "login" || cmd === "startup") {
  if (["enable", "install", "on"].includes(loginAction)) {
    await installLaunchAgent(startupFlags);
  } else if (["disable", "remove", "uninstall", "off"].includes(loginAction)) {
    uninstallLaunchAgent();
  } else if (loginAction === "status") {
    printAppStatus();
  } else {
    console.log("Usage: lats app login [enable|disable|status]");
  }
} else if (cmd === "status") {
  printAppStatus();
} else if (cmd === "upgrade") {
  await upgradePackage(flags.includes("--force"));
} else if (cmd === "update") {
  if (shouldDetachUpdate && !isUpdateWorker) {
    spawnDetachedUpdateWorker(launchFlags, shouldLaunchAfterUpdate);
    console.log("lattices app update started.");
  } else {
    await updateApp(launchFlags, shouldLaunchAfterUpdate);
  }
} else {
  await ensureBinary();
  launch(launchFlags);
}
