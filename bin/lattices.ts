#!/usr/bin/env bun

import { execFileSync, execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, resolve } from "node:path";
import { homedir } from "node:os";
import { loadDaemonClient, tryDaemon, withDaemon, targetHost, isRemoteTarget } from "./cli/daemon.ts";
import { printHome, printUsage } from "./cli/usage.ts";
import {
  hasFlag,
  nonFlagArgs,
  parseFlagValue,
  parseOptionalNumber,
  pause,
  run,
  runQuiet,
} from "./cli/helpers.ts";
import { searchCommand, placeCommand } from "./cli/search.ts";
import { captureCommand } from "./cli/capture.ts";
import { layerCommand } from "./cli/layer.ts";
import { displayCommand } from "./cli/display.ts";
import { stateCommand } from "./cli/state.ts";
import { runsCommand } from "./cli/runs.ts";
import { mapCommand, mapUsage } from "./cli/map.ts";
import { hostsCommand } from "./cli/hosts.ts";
import {
  esc,
  sessionExists,
  slugify,
  toGroupSessionName,
  toSessionName,
} from "./cli/session.ts";

import { supportsRemote } from "./cli/remote.ts";
import { resolveDisplayNames } from "./cli/display-names.ts";

const args: string[] = process.argv.slice(2);

// `lats --host <name> ...` sends daemon calls to another lattices host, such as
// a Linux machine running lattices-host on the tailnet (LAT-013).
const hostFlag = args.indexOf("--host");
if (hostFlag !== -1 && hostFlag < args.length - 1) {
  const [, host] = args.splice(hostFlag, 2);
  const [name, port] = host.split(":");
  process.env.LATTICES_DAEMON_HOST = name;
  if (port) process.env.LATTICES_DAEMON_PORT = port;
}
if (args[0]?.startsWith("@")) {
  const host = args.shift()!.slice(1);
  if (!host || (host !== "local" && !supportsRemote(args))) {
    console.error(`${args[0] ?? "home screen"} is local-only. Use lats @${host || "host"} call <method> for daemon methods.`);
    process.exit(1);
  }
  targetHost(host);
}
const command: string | undefined = args[0];

// ── Helpers ──────────────────────────────────────────────────────────

function hasTmux(): boolean {
  return runQuiet("which tmux") !== null;
}

/** Commands that require tmux to be installed */
const tmuxRequiredCommands = new Set([
  "start", "tmux", "init", "ls", "list", "kill", "rm", "sync", "reconcile",
  "restart", "respawn", "group", "groups", "tab", "status",
  "inventory", "sessions",
]);

function requireTmux(command: string | undefined): void {
  if (isRemoteTarget() || hasTmux()) return;

  if (!command) return;

  if (!tmuxRequiredCommands.has(command)) return;

  console.error(`
\x1b[1;31m✘ tmux not found\x1b[0m

Lattices uses tmux for terminal session management.
Install it with Homebrew:

    \x1b[1mbrew install tmux\x1b[0m

If tmux is installed somewhere else, make sure it's on your PATH:

    \x1b[90mexport PATH="/path/to/tmux/bin:$PATH"\x1b[0m

Then run this command again.
`.trim());
  process.exit(1);
}

function isInsideTmux(): boolean {
  return !!process.env.TMUX;
}

function appleScriptString(str: string): string {
  return str.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

// ── Config ───────────────────────────────────────────────────────────

function readConfig(dir: string): any | null {
  const configPath = resolve(dir, ".lattices.json");
  if (!existsSync(configPath)) return null;
  try {
    const raw = readFileSync(configPath, "utf8");
    return JSON.parse(raw);
  } catch (e: unknown) {
    console.warn(`Warning: invalid .lattices.json — ${(e as Error).message}`);
    return null;
  }
}

// ── Workspace config (tab groups) ───────────────────────────────────

function readWorkspaceConfig(): any | null {
  const configPath = resolve(homedir(), ".lattices", "workspace.json");
  if (!existsSync(configPath)) return null;
  try {
    const raw = readFileSync(configPath, "utf8");
    return JSON.parse(raw);
  } catch (e: unknown) {
    console.warn(`Warning: invalid workspace.json — ${(e as Error).message}`);
    return null;
  }
}

/** Get ordered pane IDs for a specific window within a session */
function getPaneIdsForWindow(sessionName: string, windowIndex: number): string[] {
  const out = runQuiet(
    `tmux list-panes -t "${sessionName}:${windowIndex}" -F "#{pane_id}"`
  );
  return out ? out.split("\n").filter(Boolean) : [];
}

interface PaneConfig {
  name?: string;
  cmd?: string;
  size?: number;
}

/** Create a tmux window with pane layout for a project dir */
function createWindowForProject(sessionName: string, windowIndex: number, dir: string, label?: string): void {
  const config = readConfig(dir);
  const d = esc(dir);

  let panes: PaneConfig[];
  if (config?.panes?.length) {
    panes = resolvePane(config.panes, dir);
  } else {
    panes = defaultPanes(dir);
  }

  if (windowIndex === 0) {
    // First window already exists from new-session, just set working dir
    run(`tmux send-keys -t "${sessionName}:0" 'cd ${d}' Enter`);
  } else {
    run(`tmux new-window -t "${sessionName}" -c '${d}'`);
  }

  const winTarget = `${sessionName}:${windowIndex}`;

  // Rename the window
  const winLabel = label || basename(dir);
  runQuiet(`tmux rename-window -t "${winTarget}" "${winLabel}"`);

  // Create pane splits
  if (panes.length === 2) {
    const mainSize = panes[0].size || 60;
    run(`tmux split-window -h -t "${winTarget}" -c '${d}' -p ${100 - mainSize}`);
  } else if (panes.length >= 3) {
    const mainSize = panes[0].size || 60;
    for (let i = 1; i < panes.length; i++) {
      run(`tmux split-window -t "${winTarget}" -c '${d}'`);
    }
    runQuiet(`tmux set-option -t "${winTarget}" -w main-pane-width '${mainSize}%'`);
    run(`tmux select-layout -t "${winTarget}" main-vertical`);
  }

  // Get pane IDs and send commands
  const paneIds = getPaneIdsForWindow(sessionName, windowIndex);
  for (let i = 0; i < panes.length && i < paneIds.length; i++) {
    if (panes[i].cmd) {
      run(`tmux send-keys -t "${paneIds[i]}" '${esc(panes[i].cmd!)}' Enter`);
    }
    if (panes[i].name) {
      runQuiet(`tmux select-pane -t "${paneIds[i]}" -T "${panes[i].name}"`);
    }
  }

  // Focus first pane in this window
  if (paneIds.length) {
    run(`tmux select-pane -t "${paneIds[0]}"`);
  }
}

interface TabConfig {
  path?: string;
  label?: string;
  app?: string;
  title?: string;
  url?: string;
  launch?: string;
}

interface GroupConfig {
  id: string;
  label?: string;
  tabs?: TabConfig[];
}

function projectTabs(tabs: TabConfig[]): Array<TabConfig & { path: string }> {
  return tabs.filter((tab): tab is TabConfig & { path: string } => Boolean(tab.path));
}

function tabLabel(tab: TabConfig): string {
  return tab.label || (tab.path ? basename(tab.path) : tab.app || tab.title || "Tab");
}

function openExternalTab(tab: TabConfig): void {
  if (tab.url) {
    run(`open '${esc(tab.url)}'`);
    return;
  }
  const app = tab.launch || tab.app;
  if (app) run(`open -a '${esc(app)}'`);
}

/** Create a group session with one tmux window per tab */
function createGroupSession(group: GroupConfig): string | null {
  const name = toGroupSessionName(group.id);
  const tabs = projectTabs(group.tabs || []);

  if (!tabs.length) {
    console.log(`Group "${group.id}" has no tabs.`);
    return null;
  }

  // Validate all paths exist
  for (const tab of tabs) {
    if (!existsSync(tab.path)) {
      console.log(`Warning: path does not exist — ${tab.path}`);
    }
  }

  const firstDir = esc(tabs[0].path);
  console.log(`Creating group "${group.label || group.id}" (${tabs.length} tabs)...`);

  // Create session with first window
  run(`tmux new-session -d -s "${name}" -c '${firstDir}'`);

  // Set up each window/tab
  for (let i = 0; i < tabs.length; i++) {
    const tab = tabs[i];
    const dir = resolve(tab.path);
    createWindowForProject(name, i, dir, tab.label);
  }

  // Tag the session title
  runQuiet(`tmux set-option -t "${name}" set-titles on`);
  runQuiet(`tmux set-option -t "${name}" set-titles-string "[lattices:${name}] #{window_name} — #{pane_title}"`);

  // Select first window
  runQuiet(`tmux select-window -t "${name}:0"`);

  return name;
}

function listGroups(): void {
  const ws = readWorkspaceConfig();
  if (!ws?.groups?.length) {
    console.log("No tab groups configured in ~/.lattices/workspace.json");
    return;
  }

  console.log("Tab Groups:\n");
  for (const group of ws.groups) {
    const tabs = group.tabs || [];
    const terminalTabs = projectTabs(tabs);
    const runningCount = terminalTabs.filter(
      (t) => sessionExists(toSessionName(resolve(t.path)))
    ).length;
    const running = runningCount > 0;
    const status = terminalTabs.length === 0
      ? "\x1b[36m◆ app tabs\x1b[0m"
      : running
      ? `\x1b[32m● ${runningCount}/${terminalTabs.length} terminal tabs running\x1b[0m`
      : "\x1b[90m○ stopped\x1b[0m";
    const tabLabels = tabs.map(tabLabel).join(", ");
    console.log(`  ${group.label || group.id}  ${status}`);
    console.log(`    id: ${group.id}`);
    console.log(`    tabs: ${tabLabels}`);
    console.log();
  }
}

function groupCommand(id?: string): void {
  const ws = readWorkspaceConfig();
  if (!ws?.groups?.length) {
    console.log("No tab groups configured in ~/.lattices/workspace.json");
    return;
  }

  if (!id) {
    listGroups();
    return;
  }

  const group = ws.groups.find((g: GroupConfig) => g.id === id);
  if (!group) {
    console.log(`No group "${id}". Available: ${ws.groups.map((g: GroupConfig) => g.id).join(", ")}`);
    return;
  }

  const tabs = group.tabs || [];
  if (!tabs.length) {
    console.log(`Group "${group.id}" has no tabs.`);
    return;
  }

  const terminalTabs = projectTabs(tabs);
  for (const tab of tabs.filter((tab: TabConfig) => !tab.path)) openExternalTab(tab);
  if (!terminalTabs.length) {
    console.log(`Opened "${group.label || group.id}" app tabs.`);
    return;
  }

  // Each project tab gets its own lattices session.
  const firstDir = resolve(terminalTabs[0].path);
  const firstName = toSessionName(firstDir);

  // If the first tab's session already exists, just attach
  if (sessionExists(firstName)) {
    console.log(`Reattaching to "${group.label || group.id}" (${tabLabel(terminalTabs[0])})...`);
    attach(firstName);
    return;
  }

  // Create a detached session for each tab
  console.log(`Launching group "${group.label || group.id}" (${tabs.length} tabs)...`);
  for (const tab of terminalTabs) {
    const dir = resolve(tab.path);
    const name = toSessionName(dir);
    if (!sessionExists(name)) {
      console.log(`  Creating session: ${tabLabel(tab)}`);
      createSession(dir);
    }
  }

  // Attach to the first tab's session
  attach(firstName);
}

function tabCommand(groupId?: string, tabName?: string): void {
  if (!groupId) {
    console.log("Usage: lats tab <group-id> <tab-name|index>");
    return;
  }

  const ws = readWorkspaceConfig();
  if (!ws?.groups?.length) {
    console.log("No tab groups configured.");
    return;
  }

  const group = ws.groups.find((g: GroupConfig) => g.id === groupId);
  if (!group) {
    console.log(`No group "${groupId}".`);
    return;
  }

  const tabs: TabConfig[] = group.tabs || [];

  if (!tabName) {
    // List tabs with their session status
    console.log(`Tabs in "${group.label || group.id}":\n`);
    for (let i = 0; i < tabs.length; i++) {
      const tab = tabs[i];
      const label = tabLabel(tab);
      if (tab.path) {
        const tabSession = toSessionName(resolve(tab.path));
        const running = sessionExists(tabSession);
        const status = running ? "\x1b[32m●\x1b[0m" : "\x1b[90m○\x1b[0m";
        console.log(`  ${status} ${i}: ${label}  (session: ${tabSession})`);
      } else {
        console.log(`  \x1b[36m◆\x1b[0m ${i}: ${label}  (app tab)`);
      }
    }
    return;
  }

  // Resolve tab target to an index
  let tabIdx: number;
  if (/^\d+$/.test(tabName)) {
    tabIdx = parseInt(tabName, 10);
  } else {
    tabIdx = tabs.findIndex(
      (t) => tabLabel(t).toLowerCase() === tabName.toLowerCase()
    );
    if (tabIdx === -1) {
      const available = tabs.map(tabLabel).join(", ");
      console.log(`No tab "${tabName}". Available: ${available}`);
      return;
    }
  }

  if (tabIdx < 0 || tabIdx >= tabs.length) {
    console.log(`Tab index ${tabIdx} is out of range (${tabs.length} tabs).`);
    return;
  }

  const selectedTab = tabs[tabIdx];
  if (!selectedTab.path) {
    console.log(`Opening app tab: ${tabLabel(selectedTab)}`);
    openExternalTab(selectedTab);
    return;
  }

  // Each project tab is its own lattices session — attach to it.
  const dir = resolve(selectedTab.path);
  const tabSession = toSessionName(dir);
  const label = tabLabel(selectedTab);

  if (sessionExists(tabSession)) {
    console.log(`Attaching to tab: ${label}`);
    attach(tabSession);
  } else {
    console.log(`Creating session for tab: ${label}`);
    createSession(dir);
    attach(tabSession);
  }
}

// ── Detect dev command ───────────────────────────────────────────────

function detectPackageManager(dir: string): string {
  if (existsSync(resolve(dir, "bun.lockb")) || existsSync(resolve(dir, "bun.lock")))
    return "bun";
  if (existsSync(resolve(dir, "pnpm-lock.yaml"))) return "pnpm";
  if (existsSync(resolve(dir, "yarn.lock"))) return "yarn";
  return "npm";
}

function detectDevCommand(dir: string): string | null {
  const pkgPath = resolve(dir, "package.json");
  if (!existsSync(pkgPath)) return null;

  let pkg: any;
  try {
    pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
  } catch {
    return null;
  }

  const scripts = pkg.scripts || {};
  const pm = detectPackageManager(dir);
  const runCmd = pm === "npm" ? "npm run" : pm;

  if (scripts.dev) return `${runCmd} dev`;
  if (scripts.start) return `${runCmd} start`;
  if (scripts.serve) return `${runCmd} serve`;
  if (scripts.watch) return `${runCmd} watch`;
  return null;
}

// ── Session creation ─────────────────────────────────────────────────

function resolvePane(panes: any[], dir: string): PaneConfig[] {
  return panes.map((p: any) => ({
    name: p.name || "",
    cmd: p.cmd || undefined,
    size: p.size || undefined,
  }));
}

/** Get ordered pane IDs (e.g. ["%0", "%1"]) for a session */
function getPaneIds(name: string): string[] {
  const out = runQuiet(
    `tmux list-panes -t "${name}" -F "#{pane_id}"`
  );
  return out ? out.split("\n").filter(Boolean) : [];
}

function createSession(dir: string): string {
  const name = toSessionName(dir);
  const config = readConfig(dir);
  const d = esc(dir);

  let panes: PaneConfig[];
  if (config?.panes?.length) {
    panes = resolvePane(config.panes, dir);
    console.log(`Using .lattices.json (${panes.length} panes)`);
  } else {
    panes = defaultPanes(dir);
    if (panes.length > 1) console.log(`Detected: ${panes[1].cmd}`);
    else console.log(`No dev server detected — single pane`);
  }

  // Create session (targets are config-agnostic — no hardcoded indices)
  run(`tmux new-session -d -s "${name}" -c '${d}'`);

  if (panes.length === 2) {
    const mainSize = panes[0].size || 60;
    run(
      `tmux split-window -h -t "${name}" -c '${d}' -p ${100 - mainSize}`
    );
  } else if (panes.length >= 3) {
    const mainSize = panes[0].size || 60;
    for (let i = 1; i < panes.length; i++) {
      run(`tmux split-window -t "${name}" -c '${d}'`);
    }
    runQuiet(
      `tmux set-option -t "${name}" -w main-pane-width '${mainSize}%'`
    );
    run(`tmux select-layout -t "${name}" main-vertical`);
  }

  // Get actual pane IDs (works regardless of base-index / pane-base-index)
  const paneIds = getPaneIds(name);

  // Send commands and name each pane
  for (let i = 0; i < panes.length && i < paneIds.length; i++) {
    if (panes[i].cmd) {
      run(`tmux send-keys -t "${paneIds[i]}" '${esc(panes[i].cmd!)}' Enter`);
    }
    if (panes[i].name) {
      runQuiet(`tmux select-pane -t "${paneIds[i]}" -T "${panes[i].name}"`);
    }
  }

  // Tag the terminal window title so the menu bar app can find it
  // Format: [lattices:session-hash] pane_title: current_command
  runQuiet(`tmux set-option -t "${name}" set-titles on`);
  runQuiet(`tmux set-option -t "${name}" set-titles-string "[lattices:${name}] #{pane_title}"`);

  // Name the tmux window after the project and focus the first pane
  runQuiet(`tmux rename-window -t "${name}" "${basename(dir)}"`);
  if (paneIds.length) {
    run(`tmux select-pane -t "${paneIds[0]}"`);
  }

  return name;
}

/** Check each pane and prefill or restart commands that have exited.
 *  mode: "prefill" types the command without pressing Enter
 *  mode: "ensure" types the command and presses Enter */
function restoreCommands(name: string, dir: string, mode: "prefill" | "ensure"): void {
  const config = readConfig(dir);
  let panes: PaneConfig[];
  if (config?.panes?.length) {
    panes = resolvePane(config.panes, dir);
  } else {
    panes = defaultPanes(dir);
  }

  const paneIds = getPaneIds(name);
  const shells = new Set(["bash", "zsh", "fish", "sh", "dash"]);

  let count = 0;
  for (let i = 0; i < panes.length && i < paneIds.length; i++) {
    if (!panes[i].cmd) continue;
    const cur = runQuiet(
      `tmux display-message -t "${paneIds[i]}" -p "#{pane_current_command}"`
    );
    if (cur && shells.has(cur)) {
      if (mode === "ensure") {
        run(`tmux send-keys -t "${paneIds[i]}" '${esc(panes[i].cmd!)}' Enter`);
      } else {
        run(`tmux send-keys -t "${paneIds[i]}" '${esc(panes[i].cmd!)}'`);
      }
      count++;
    }
  }
  if (count > 0) {
    const verb = mode === "ensure" ? "Restarted" : "Prefilled";
    console.log(`${verb} ${count} exited command${count > 1 ? "s" : ""}`);
  }
}

// ── Sync / reconcile ────────────────────────────────────────────────

function resolvePanes(dir: string): PaneConfig[] {
  const config = readConfig(dir);
  if (config?.panes?.length) {
    return resolvePane(config.panes, dir);
  }
  return defaultPanes(dir);
}

// ── Dev command ──────────────────────────────────────────────────────

function detectProjectType(dir: string): string | null {
  // Check for lattices-style hybrid project (Swift app + Node CLI)
  if (existsSync(resolve(dir, "apps/mac/Package.swift")) && existsSync(resolve(dir, "bin/lattices-app.ts")))
    return "lattices-app";
  if (existsSync(resolve(dir, "Package.swift"))) return "swift";
  if (existsSync(resolve(dir, "Cargo.toml"))) return "rust";
  if (existsSync(resolve(dir, "go.mod"))) return "go";
  if (existsSync(resolve(dir, "package.json"))) return "node";
  if (existsSync(resolve(dir, "Makefile"))) return "make";
  return null;
}

async function forwardToLatticesDevHelper(dir: string, cmd: string, extraFlags: string[] = []): Promise<void> {
  const localDevScript = resolve(dir, "bin/lattices-dev");
  const devScript = existsSync(localDevScript) ? localDevScript : resolve(import.meta.dir, "lattices-dev");
  const { execFileSync } = await import("node:child_process");
  try {
    execFileSync(devScript, [cmd, ...extraFlags], { stdio: "inherit" });
  } catch {
    /* exit code forwarded */
  }
}

async function devCommand(sub?: string, ...flags: string[]): Promise<void> {
  const dir = process.cwd();
  const type = detectProjectType(dir);

  if (!sub) {
    // bare `lats dev` — run dev server
    if (!type) {
      console.log("No recognized project in current directory.");
      return;
    }
    console.log(`Detected: ${type} project`);
    if (type === "lattices-app") {
      await forwardToLatticesDevHelper(dir, "restart", flags);
    } else if (type === "node") {
      const cmd = detectDevCommand(dir);
      if (cmd) {
        console.log(`Running: ${cmd}`);
        execSync(cmd, { cwd: dir, stdio: "inherit" });
      } else {
        console.log("No dev script found in package.json.");
      }
    } else if (type === "swift") {
      console.log("Running: swift run");
      execSync("swift run", { cwd: dir, stdio: "inherit" });
    } else if (type === "rust") {
      console.log("Running: cargo run");
      execSync("cargo run", { cwd: dir, stdio: "inherit" });
    } else if (type === "go") {
      console.log("Running: go run .");
      execSync("go run .", { cwd: dir, stdio: "inherit" });
    } else if (type === "make") {
      execSync("make", { cwd: dir, stdio: "inherit" });
    }
    return;
  }

  if (sub === "placement-smoke") {
    await placementSmokeCommand(flags);
    return;
  }

  if (sub === "build") {
    if (!type) {
      console.log("No recognized project in current directory.");
      return;
    }
    if (type === "lattices-app") {
      await forwardToLatticesDevHelper(dir, "build");
    } else if (type === "swift") {
      console.log("Building: swift build -c release");
      execSync("swift build -c release", { cwd: dir, stdio: "inherit" });
    } else if (type === "node") {
      const pm = detectPackageManager(dir);
      const runCmd = pm === "npm" ? "npm run" : pm;
      const pkg = JSON.parse(readFileSync(resolve(dir, "package.json"), "utf8"));
      if (pkg.scripts?.build) {
        console.log(`Running: ${runCmd} build`);
        execFileSync(pm, pm === "npm" ? ["run", "build"] : ["build"], { cwd: dir, stdio: "inherit" });
      } else {
        console.log("No build script found in package.json.");
      }
    } else if (type === "rust") {
      console.log("Building: cargo build --release");
      execSync("cargo build --release", { cwd: dir, stdio: "inherit" });
    } else if (type === "go") {
      console.log("Building: go build .");
      execSync("go build .", { cwd: dir, stdio: "inherit" });
    } else if (type === "make") {
      execSync("make", { cwd: dir, stdio: "inherit" });
    }
    return;
  }

  if (sub === "restart") {
    if (type === "lattices-app") {
      await forwardToLatticesDevHelper(dir, "restart", flags);
    } else {
      // For other project types, just rebuild
      await devCommand("build");
    }
    return;
  }

  if (sub === "type") {
    console.log(type || "unknown");
    return;
  }

  console.log(`Unknown dev subcommand: ${sub}`);
  console.log("Usage: lats dev [build|restart|type]");
}

function defaultPanes(dir: string): PaneConfig[] {
  const devCmd = detectDevCommand(dir);
  if (devCmd) {
    return [
      { name: "shell", size: 60 },
      { name: "server", cmd: devCmd },
    ];
  }
  // No dev server detected → single pane
  return [{ name: "shell" }];
}

function syncSession(): void {
  const dir = process.cwd();
  const name = toSessionName(dir);

  if (!sessionExists(name)) {
    console.log(`No session "${name}" — creating from scratch.`);
    createSession(dir);
    console.log("Session created.");
    return;
  }

  const panes = resolvePanes(dir);
  const actualIds = getPaneIds(name);
  const declared = panes.length;
  const actual = actualIds.length;
  const d = esc(dir);
  const shells = new Set(["bash", "zsh", "fish", "sh", "dash"]);

  console.log(`Session "${name}": ${actual} pane(s) found, ${declared} declared.`);

  // Phase 1: recreate missing panes
  if (actual < declared) {
    const missing = declared - actual;
    console.log(`Recreating ${missing} missing pane(s)...`);
    for (let i = 0; i < missing; i++) {
      run(`tmux split-window -t "${name}" -c '${d}'`);
    }

    // Re-apply layout
    if (declared === 2) {
      const mainSize = panes[0].size || 60;
      // With 2 panes, use horizontal split layout
      run(`tmux select-layout -t "${name}" even-horizontal`);
      runQuiet(
        `tmux set-option -t "${name}" -w main-pane-width '${mainSize}%'`
      );
      run(`tmux select-layout -t "${name}" main-vertical`);
    } else if (declared >= 3) {
      const mainSize = panes[0].size || 60;
      runQuiet(
        `tmux set-option -t "${name}" -w main-pane-width '${mainSize}%'`
      );
      run(`tmux select-layout -t "${name}" main-vertical`);
    }
  }

  // Phase 2: restore commands and labels on all panes
  const freshIds = getPaneIds(name);
  let restored = 0;
  for (let i = 0; i < panes.length && i < freshIds.length; i++) {
    // Set pane title/label
    if (panes[i].name) {
      runQuiet(`tmux select-pane -t "${freshIds[i]}" -T "${panes[i].name}"`);
    }
    // If pane is idle at a shell prompt, send its declared command
    if (panes[i].cmd) {
      const cur = runQuiet(
        `tmux display-message -t "${freshIds[i]}" -p "#{pane_current_command}"`
      );
      if (cur && shells.has(cur)) {
        run(`tmux send-keys -t "${freshIds[i]}" '${esc(panes[i].cmd!)}' Enter`);
        restored++;
      }
    }
  }

  // Focus first pane
  if (freshIds.length) {
    run(`tmux select-pane -t "${freshIds[0]}"`);
  }

  if (restored > 0) {
    console.log(`Restarted ${restored} command(s).`);
  }
  console.log("Sync complete.");
}

// ── Restart pane ────────────────────────────────────────────────────

function restartPane(target?: string): void {
  const dir = process.cwd();
  const name = toSessionName(dir);

  if (!sessionExists(name)) {
    console.log(`No session "${name}".`);
    return;
  }

  const panes = resolvePanes(dir);
  const paneIds = getPaneIds(name);

  // Resolve target to an index
  let idx: number;
  if (target === undefined || target === null || target === "") {
    // Default: first pane
    idx = 0;
  } else if (/^\d+$/.test(target)) {
    idx = parseInt(target, 10);
  } else {
    // Match by name (case-insensitive)
    idx = panes.findIndex(
      (p) => p.name && p.name.toLowerCase() === target.toLowerCase()
    );
    if (idx === -1) {
      console.log(
        `No pane named "${target}". Available: ${panes.map((p, i) => p.name || `[${i}]`).join(", ")}`
      );
      return;
    }
  }

  if (idx < 0 || idx >= paneIds.length) {
    console.log(`Pane index ${idx} is out of range (${paneIds.length} panes).`);
    return;
  }

  const paneId = paneIds[idx];
  const pane = panes[idx] || {};
  const label = pane.name || `pane ${idx}`;

  // Get the PID of the process running in the pane
  const panePid = runQuiet(
    `tmux display-message -t "${paneId}" -p "#{pane_pid}"`
  );

  // Step 1: try C-c to gracefully stop
  console.log(`Stopping ${label}...`);
  run(`tmux send-keys -t "${paneId}" C-c`);

  // Brief pause to let C-c propagate
  execSync("sleep 0.5");

  // Step 2: check if the process is still running (not back to shell)
  const shells = new Set(["bash", "zsh", "fish", "sh", "dash"]);
  const cur = runQuiet(
    `tmux display-message -t "${paneId}" -p "#{pane_current_command}"`
  );

  if (cur && !shells.has(cur)) {
    // Still hung — escalate: kill the child processes of the pane
    console.log(`Process still running (${cur}), sending SIGKILL...`);
    if (panePid) {
      // Kill all children of the pane's shell process
      runQuiet(`pkill -KILL -P ${panePid}`);
      execSync("sleep 0.3");
    }
  }

  // Step 3: send the declared command
  if (pane.cmd) {
    console.log(`Starting: ${pane.cmd}`);
    run(`tmux send-keys -t "${paneId}" '${esc(pane.cmd)}' Enter`);
  } else {
    console.log(`No command declared for ${label} — pane is at shell prompt.`);
  }
}

// ── Commands ─────────────────────────────────────────────────────────

// ── Daemon-aware commands ────────────────────────────────────────────

async function mouseCommand(sub?: string): Promise<void> {
  if (sub && !["find", "summon", "home"].includes(sub)) throw new Error("Usage: lats mouse [find|summon|home]");
  await withDaemon(async ({ daemonCall }) => {
    if (sub === "summon") {
      const result = await daemonCall("mouse.summon") as any;
      console.log(`🎯 Mouse summoned to (${result.x}, ${result.y})`);
    } else if (sub === "home") {
      await daemonCall("mouse.home");
      console.log("🏠 Pointer home");
    } else {
      // Default: find
      const result = await daemonCall("mouse.find") as any;
      console.log(`🔍 Mouse at (${result.x}, ${result.y})`);
    }
  });
}

async function visitCommand(sub?: string, rest: string[] = []): Promise<void> {
  await withDaemon(async ({ daemonCall }) => {
    if (sub === "pair") {
      const [host, address, side] = rest;
      if (!host) return console.log("Usage: lats visit pair <host> [host:port] [left|right|top|bottom]");
      const result = await daemonCall("visit.pair", { host, ...(address ? { address } : {}), ...(side ? { side } : {}) }) as any;
      console.log(`🔐 Approve ${result.code} on ${result.pairing}, then: lats visit status`);
    } else if (sub === "main") {
      const n = rest[0];
      if (!n) throw new Error("Usage: lats visit main <n>");
      await daemonCall("visit.main", { screen: n });
      console.log(`Display ${n} is main. It reverts in 15s unless you run "lats visit arrangement keep".`);
    } else if (sub === "arrangement") {
      if (!["keep", "revert"].includes(rest[0])) throw new Error("Usage: lats visit arrangement <keep|revert>");
      await daemonCall(`visit.arrangement.${rest[0]}`);
      console.log(`Arrangement: ${rest[0]}`);
    } else if (sub === "place") {
      const [name, rawX, rawY] = rest;
      const x = Number(rawX), y = Number(rawY);
      if (!name || rawX === undefined || rawY === undefined || !Number.isFinite(x) || !Number.isFinite(y)) {
        throw new Error("Usage: lats visit place <name> <x> <y>");
      }
      await daemonCall("visit.place", { name, x, y });
      console.log(`${name}: (${x}, ${y})`);
    } else if (sub === "host") {
      if (!["on", "off"].includes(rest[0])) throw new Error("Usage: lats visit host <on|off>");
      await daemonCall("visit.host", { on: rest[0] === "on" });
      console.log(`Receiving visits ${rest[0]}`);
    } else if (sub === "forget" || sub === "side") {
      const [host, side] = rest;
      if (!host || (sub === "side" && !["left", "right", "top", "bottom"].includes(side))) {
        return console.log(`Usage: lats visit ${sub} <host>${sub === "side" ? " <left|right|top|bottom>" : ""}`);
      }
      const result = await daemonCall(`visit.${sub}`, { host, ...(sub === "side" ? { side } : {}) }) as any;
      console.log(result.ok ? (sub === "side" ? `${host}: ${side}` : `Forgot ${host}`) : `No paired host named ${host}`);
    } else if (sub === "on" || sub === "off") {
      const result = await daemonCall("visit.arm", { on: sub === "on" }) as any;
      console.log(result.armed ? "🖱️ Visiting armed: push past an edge facing a paired host" : "Visiting off");
    } else if (sub === "end") {
      await daemonCall("visit.end");
      console.log("🏠 Visit ended");
    } else if (sub === "screens" || sub === "elsewhere" || sub === "here") {
      const n = rest[0];
      if (sub !== "screens") {
        if (!n) return console.log(`Usage: lats visit ${sub} <display number>  (see: lats visit screens)`);
        const result = await daemonCall("visit.elsewhere", { screen: n, on: sub === "elsewhere", ...(rest[1] ? { name: rest[1] === "--clear" ? "" : rest[1] } : {}) }) as any;
        if (!result.ok) return console.log(`No display ${n}. See: lats visit screens`);
      }
      const screens = await daemonCall("visit.screens") as any[];
      for (const d of screens) console.log(`  ${d.number}  ${d.name}  ${d.frame.w}×${d.frame.h}${d.main ? "  main" : ""}${d.elsewhere ? "  elsewhere" : ""}${d.machine ? ` · ${d.machine}` : ""}`);
    } else if (sub && sub !== "status") {
      const result = await daemonCall("visit.start", { host: sub });
      console.log(JSON.stringify(result));
    } else {
      const s = await daemonCall("visit.status") as any;
      for (const h of s.hosts) console.log(`  ${s.visiting === h.name ? "●" : "○"} ${h.name}  ${h.side ?? "unplaced"}  ${h.address}  ${h.fingerprint}`);
      if (!s.hosts.length) console.log("No paired hosts. Pair with: lats visit pair <host>");
      console.log(`${s.armed ? "Armed" : "Off"} · this Mac's code ${s.code}`);
    }
  });
}

async function daemonStatusCommand(): Promise<void> {
  const status = await tryDaemon(async ({ daemonCall }) =>
    daemonCall("daemon.status") as Promise<any>
  );
  if (!status) {
    console.log("\x1b[90m○\x1b[0m Daemon not running (start with: lats app)");
    return;
  }
  const uptime = Math.round(status.uptime);
  const h = Math.floor(uptime / 3600);
  const m = Math.floor((uptime % 3600) / 60);
  const s = uptime % 60;
  const uptimeStr = h > 0 ? `${h}h ${m}m ${s}s` : m > 0 ? `${m}m ${s}s` : `${s}s`;
  console.log(`\x1b[32m●\x1b[0m Daemon running on ws://127.0.0.1:9399`);
  console.log(`  uptime:    ${uptimeStr}`);
  console.log(`  clients:   ${status.clientCount}`);
  console.log(`  windows:   ${status.windowCount}`);
  console.log(`  sessions:  ${status.tmuxSessionCount}`);
  console.log(`  version:   ${status.version}`);
}

async function windowsCommand(jsonFlag: boolean): Promise<void> {
  await withDaemon(async ({ daemonCall }) => {
    const windows = await daemonCall("windows.list") as any[];
    if (jsonFlag) {
      console.log(JSON.stringify(windows, null, 2));
      return;
    }
    if (!windows.length) {
      console.log("No windows tracked.");
      return;
    }
    console.log(`Windows (${windows.length}):\n`);
    for (const w of windows) {
      const session = w.latticesSession ? `  \x1b[36m[lattices:${w.latticesSession}]\x1b[0m` : "";
      const spaces = w.spaceIds.length ? ` space:${w.spaceIds.join(",")}` : "";
      console.log(`  \x1b[1m${w.app}\x1b[0m  wid:${w.wid}${spaces}${session}`);
      console.log(`    "${w.title}"`);
      console.log(`    ${Math.round(w.frame.w)}×${Math.round(w.frame.h)} at (${Math.round(w.frame.x)},${Math.round(w.frame.y)})`);
      console.log();
    }
  });
}

/** The old tag command: now puts the window in the ⌘⌥ layer. */
async function windowAssignCommand(wid?: string, layer?: string): Promise<void> {
  if (!wid || !layer) {
    console.log("Usage: lats layer add wid:N --to <layer>");
    return;
  }
  await withDaemon(async ({ daemonCall }) => {
    const result = await daemonCall("layers.assign", { wid: parseInt(wid), layer }) as any;
    console.log(result.added ? `Added wid:${wid} to ${layer}` : `${layer} already holds wid:${wid}`);
  });
}

async function focusCommand(session?: string): Promise<void> {
  if (!session) {
    console.log("Usage: lats focus <session-name>");
    return;
  }
  await withDaemon(async ({ daemonCall }) => {
    await daemonCall("windows.focus", { session });
    console.log(`Focused: ${session}`);
  });
}

function receiptLine(receipt: any): string {
  const id = receipt?.action?.id || "action";
  const session = receipt?.session || receipt?.target?.session || "?";
  const wid = receipt?.wid ?? receipt?.target?.wid ?? "?";
  const status = receipt?.status || "?";
  const verified = receipt?.verified === true ? "true" : "false";
  const resolution = receipt?.targetResolution || "?";
  return `  ${id}  session=${session}  wid=${wid}  status=${status}  verified=${verified}  resolution=${resolution}`;
}

async function placementSmokeCommand(rawArgs: string[] = []): Promise<void> {
  const pauseMs = Number(parseFlagValue(rawArgs, "pause") || 1200);
  const positional = nonFlagArgs(rawArgs);

  await withDaemon(async ({ daemonCall }) => {
    let sessions = positional.slice(0, 2);
    if (sessions.length < 2) {
      const tmuxSessions = await daemonCall("tmux.list") as any[];
      sessions = tmuxSessions
        .map(s => s?.name)
        .filter((name: unknown): name is string => typeof name === "string" && name.startsWith("lattices-place-"))
        .slice(0, 2);
    }

    if (sessions.length < 2) {
      console.log("Need two named sessions. Usage: lats dev placement-smoke <session-a> <session-b>");
      console.log("Tip: launch two small lattices fixture projects first, then rerun this command.");
      return;
    }

    const [a, b] = sessions;
    console.log(`Placement smoke: ${a} + ${b}`);

    for (const session of sessions) {
      const resolved = await daemonCall("windows.resolve", {
        target: { kind: "session", session },
        placement: "left",
      }) as any;
      console.log(`  resolve ${session}: wid=${resolved.wid ?? "?"} app=${resolved.app ?? "?"} resolution=${resolved.targetResolution ?? "?"}`);
    }

    const beats = [
      {
        label: "beat 1: halves",
        actions: [
          { id: "a-left-half", type: "window.place", target: { kind: "session", session: a }, args: { placement: "left" } },
          { id: "b-right-half", type: "window.place", target: { kind: "session", session: b }, args: { placement: "right" } },
        ],
      },
      {
        label: "beat 2: 4x4 corners",
        actions: [
          { id: "a-top-left-4x4", type: "window.place", target: { kind: "session", session: a }, args: { placement: "grid:4x4:0,0" } },
          { id: "b-bottom-right-4x4", type: "window.place", target: { kind: "session", session: b }, args: { placement: "grid:4x4:3,3" } },
        ],
      },
      {
        label: "beat 3: workbench",
        actions: [
          {
            id: "a-workbench-left",
            type: "window.place",
            target: { kind: "session", session: a },
            args: { placement: { kind: "fractions", x: 0.02, y: 0.05, w: 0.62, h: 0.9 } },
          },
          {
            id: "b-console-right",
            type: "window.place",
            target: { kind: "session", session: b },
            args: { placement: { kind: "fractions", x: 0.67, y: 0.12, w: 0.3, h: 0.76 } },
          },
        ],
      },
    ];

    for (const beat of beats) {
      console.log(`\n${beat.label}`);
      const result = await daemonCall("actions.execute", {
        source: "placement-smoke",
        actions: beat.actions,
      }, 15000) as any;
      console.log(`  batch=${result.status || "?"} request=${result.requestId || "?"}`);
      for (const receipt of result.receipts || []) {
        console.log(receiptLine(receipt));
      }
      await pause(pauseMs);
    }

    const focused = await daemonCall("windows.focus", { session: a }, 5000) as any;
    console.log(`\nfocus ${a}: ok=${focused.ok === true} wid=${focused.wid ?? "?"} raised=${focused.raised === true}`);
  });
}

async function sessionsCommand(jsonFlag: boolean): Promise<void> {
  await withDaemon(async ({ daemonCall }) => {
    const sessions = await daemonCall("tmux.list") as any[];
    if (jsonFlag) {
      console.log(JSON.stringify(sessions, null, 2));
      return;
    }
    if (!sessions.length) {
      console.log("No active sessions.");
      return;
    }
    console.log(`Sessions (${sessions.length}):\n`);
    for (const s of sessions) {
      const windows = s.windowCount || s.windows || "?";
      console.log(`  \x1b[1m${s.name}\x1b[0m  (${windows} windows)`);
    }
  });
}

async function terminalsCommand(rawArgs: string[] = []): Promise<void> {
  await withDaemon(async ({ daemonCall }) => {
    const jsonFlag = hasFlag(rawArgs, "json");
    const refresh = hasFlag(rawArgs, "refresh");
    const terminals = await daemonCall("terminals.list", { refresh }, refresh ? 15000 : undefined) as any[];

    if (jsonFlag) {
      console.log(JSON.stringify(terminals, null, 2));
      return;
    }
    if (!terminals.length) {
      console.log("No terminal instances found.");
      return;
    }

    console.log(`Terminals (${terminals.length}):\n`);
    for (const terminal of terminals) {
      const app = terminal.app || "terminal";
      const wid = terminal.windowId ? ` wid=${terminal.windowId}` : "";
      const cwd = terminal.cwd ? ` cwd=${terminal.cwd}` : "";
      const session = terminal.tmuxSession ? ` session=${terminal.tmuxSession}` : "";
      const claude = terminal.hasClaude ? " claude" : "";
      console.log(`  ${app} ${terminal.tty}${wid}${session}${claude}`);
      if (terminal.displayName) console.log(`    ${terminal.displayName}`);
      if (cwd) console.log(`   ${cwd.trim()}`);
    }
  });
}

async function computerCommand(subcommand?: string, ...rawArgs: string[]): Promise<void> {
  const sub = subcommand || "demo-terminal";
  const jsonFlag = hasFlag(rawArgs, "json");
  const aliases: Record<string, string> = {
    "demo-terminal": "computer.demoTerminal",
    "terminal-demo": "computer.demoTerminal",
    "term-demo": "computer.demoTerminal",
    "demo-scout": "computer.demoScout",
    "scout-demo": "computer.demoScout",
    "scout": "computer.demoScout",
    "prepare": "computer.prepare",
    "observe": "computer.prepare",
    "stage": "computer.prepare",
    "launch": "computer.launchApp",
    "launch-app": "computer.launchApp",
    "app": "computer.launchApp",
    "focus": "computer.focusWindow",
    "focus-window": "computer.focusWindow",
    "click": "computer.click",
    "mouse-click": "computer.click",
    "cursor": "computer.showCursor",
    "show-cursor": "computer.showCursor",
    "mouse-cursor": "computer.showCursor",
    "magic-cursor": "computer.magicCursor",
    "ghost-cursor": "computer.magicCursor",
    "move-cursor": "computer.magicCursor",
    "magic-scout": "computer.magicCursor",
    "scout-magic": "computer.magicCursor",
    "type": "computer.typeText",
    "type-text": "computer.typeText",
    "typetext": "computer.typeText",
    "type-window": "computer.typeWindowText",
    "type-app": "computer.typeWindowText",
    "app-type": "computer.typeWindowText",
  };
  const method = aliases[sub];

  if (!method) {
    console.log(`lats computer — run bounded computer-use actions

Usage:
  lats computer prepare [--json] [--text "hello"]
  lats computer focus-window [--json] [--wid id] [--app name]
  lats computer launch-app Scout [--json]
  lats computer type-window --app Scout --text "hello" [--x-ratio .5 --y-ratio .86] [--execute]
  lats computer click --app Scout --x-ratio .5 --y-ratio .86 --treatment execute
  lats computer click --app Scout --x-ratio .74 --y-ratio .95 --transport ax --ax-label Send --execute
  lats cua click --app Scout --x-ratio .74 --y-ratio .95 --transport ax --ax-label Send --execute
  lats computer magic-scout "draft text" --execute
  lats computer scout [message] [--treatment present|execute] [--send]
  lats computer cursor [--json] [--style marker] [--shape arrow] [--size tiny] [--trail thread]
  lats computer type-text --text "hello" [--json] [--enter]
  lats computer demo-terminal [--json] [--dry-run]
  lats computer demo-terminal --text "hello" [--wid id] [--tty tty] [--iterm-session-id id] [--app iTerm2]

Common flags:
  --treatment observe|stage|present|execute
  --style spotlight|pulse|marker
  --shape arrow|needle|petal|shard|chevron|facet|wedge|prism|notch|kite
  --angle-deg -16..16
  --size tiny|small|regular|large
  --trail thread|ribbon|spark|comet|route|none
  --motion glide|snap|float|rush|crawl|accelerate|teleport|spring|magnet|slingshot
  --trajectory straight|soft|arc|swoop|overshoot
  --glow none|soft|halo|comet
  --idle still|breathe|wiggle|orbit|hover|nod|drift|shimmer|blink|tremble
  --edge none|pulse|ripple|tick|reticle|blink|spark|underline|echo|scan|pin
  --caption auto
  --caption-title "Spring reticle" --caption-body "AX text follows the cursor"
  --caption-tags "shape arrow,motion spring,edge reticle"
  --caption-placement top-left|top-right|bottom-left|bottom-right|top-center|center|near-cursor
  --caption-x-ratio 0.04 --caption-y-ratio 0.08
  --caption-lead-ms 650 --caption-sound engage
  --typewriter --type-interval-ms 18
  --transport auto|tmux|iterm|pasteboard
  --transport ax|pointer for app clicks
  --ax-label Send --no-focus
  --x-ratio 0..1 --y-ratio 0..1
  --from-x-ratio 0..1 --from-y-ratio 0..1
  --send
  --no-capture
`);
    return;
  }

  const params: Record<string, unknown> = { source: "cli" };
  const magicScout = sub === "magic-scout" || sub === "scout-magic";
  const positional = nonFlagArgs(rawArgs);
  let text = parseFlagValue(rawArgs, "text");
  const tty = parseFlagValue(rawArgs, "tty");
  const app = parseFlagValue(rawArgs, "app");
  const name = parseFlagValue(rawArgs, "name");
  const bundleId = parseFlagValue(rawArgs, "bundleId") || parseFlagValue(rawArgs, "bundle-id") || parseFlagValue(rawArgs, "bundleIdentifier");
  const path = parseFlagValue(rawArgs, "path") || parseFlagValue(rawArgs, "appPath") || parseFlagValue(rawArgs, "app-path");
  const wid = parseFlagValue(rawArgs, "wid");
  const terminalSessionId = parseFlagValue(rawArgs, "terminalSessionId")
    || parseFlagValue(rawArgs, "terminal-session-id")
    || parseFlagValue(rawArgs, "itermSessionId")
    || parseFlagValue(rawArgs, "iterm-session-id");
  const session = parseFlagValue(rawArgs, "session");
  const title = parseFlagValue(rawArgs, "title");
  const treatment = parseFlagValue(rawArgs, "treatment") || parseFlagValue(rawArgs, "mode") || parseFlagValue(rawArgs, "phase");
  const transport = parseFlagValue(rawArgs, "transport");
  const capture = parseFlagValue(rawArgs, "capture");
  const x = parseFlagValue(rawArgs, "x");
  const y = parseFlagValue(rawArgs, "y");
  const fromX = parseFlagValue(rawArgs, "fromX") || parseFlagValue(rawArgs, "from-x") || parseFlagValue(rawArgs, "startX") || parseFlagValue(rawArgs, "start-x");
  const fromY = parseFlagValue(rawArgs, "fromY") || parseFlagValue(rawArgs, "from-y") || parseFlagValue(rawArgs, "startY") || parseFlagValue(rawArgs, "start-y");
  const xRatio = parseFlagValue(rawArgs, "xRatio") || parseFlagValue(rawArgs, "x-ratio") || parseFlagValue(rawArgs, "relativeX") || parseFlagValue(rawArgs, "relative-x") || parseFlagValue(rawArgs, "windowX") || parseFlagValue(rawArgs, "window-x");
  const yRatio = parseFlagValue(rawArgs, "yRatio") || parseFlagValue(rawArgs, "y-ratio") || parseFlagValue(rawArgs, "relativeY") || parseFlagValue(rawArgs, "relative-y") || parseFlagValue(rawArgs, "windowY") || parseFlagValue(rawArgs, "window-y");
  const fromXRatio = parseFlagValue(rawArgs, "fromXRatio") || parseFlagValue(rawArgs, "from-x-ratio") || parseFlagValue(rawArgs, "startXRatio") || parseFlagValue(rawArgs, "start-x-ratio");
  const fromYRatio = parseFlagValue(rawArgs, "fromYRatio") || parseFlagValue(rawArgs, "from-y-ratio") || parseFlagValue(rawArgs, "startYRatio") || parseFlagValue(rawArgs, "start-y-ratio");
  const button = parseFlagValue(rawArgs, "button");
  const axLabel = parseFlagValue(rawArgs, "axLabel") || parseFlagValue(rawArgs, "ax-label") || parseFlagValue(rawArgs, "targetText") || parseFlagValue(rawArgs, "target-text");
  const appearance = parseFlagValue(rawArgs, "appearance") || parseFlagValue(rawArgs, "style") || parseFlagValue(rawArgs, "cursor-style") || parseFlagValue(rawArgs, "cursorStyle");
  const shape = parseFlagValue(rawArgs, "shape") || parseFlagValue(rawArgs, "marker-shape") || parseFlagValue(rawArgs, "markerShape") || parseFlagValue(rawArgs, "cursor-shape") || parseFlagValue(rawArgs, "cursorShape");
  const angleDeg = parseFlagValue(rawArgs, "angleDeg") || parseFlagValue(rawArgs, "angle-deg") || parseFlagValue(rawArgs, "rotationDeg") || parseFlagValue(rawArgs, "rotation-deg") || parseFlagValue(rawArgs, "rotation") || parseFlagValue(rawArgs, "angle");
  const size = parseFlagValue(rawArgs, "size") || parseFlagValue(rawArgs, "marker-size") || parseFlagValue(rawArgs, "markerSize") || parseFlagValue(rawArgs, "cursor-size") || parseFlagValue(rawArgs, "cursorSize");
  const color = parseFlagValue(rawArgs, "color");
  const durationMs = parseFlagValue(rawArgs, "durationMs") || parseFlagValue(rawArgs, "duration-ms");
  const typeIntervalMs = parseFlagValue(rawArgs, "typeIntervalMs")
    || parseFlagValue(rawArgs, "type-interval-ms")
    || parseFlagValue(rawArgs, "typingIntervalMs")
    || parseFlagValue(rawArgs, "typing-interval-ms");
  const label = parseFlagValue(rawArgs, "label");
  const caption = parseFlagValue(rawArgs, "caption")
    || parseFlagValue(rawArgs, "treatmentLabel")
    || parseFlagValue(rawArgs, "treatment-label")
    || parseFlagValue(rawArgs, "variant");
  const captionTitle = parseFlagValue(rawArgs, "captionTitle") || parseFlagValue(rawArgs, "caption-title");
  const captionBody = parseFlagValue(rawArgs, "captionBody")
    || parseFlagValue(rawArgs, "caption-body")
    || parseFlagValue(rawArgs, "captionDetail")
    || parseFlagValue(rawArgs, "caption-detail");
  const captionTags = parseFlagValue(rawArgs, "captionTags") || parseFlagValue(rawArgs, "caption-tags");
  const captionMode = parseFlagValue(rawArgs, "captionMode") || parseFlagValue(rawArgs, "caption-mode");
  const captionEyebrow = parseFlagValue(rawArgs, "captionEyebrow") || parseFlagValue(rawArgs, "caption-eyebrow");
  const captionLeadMs = parseFlagValue(rawArgs, "captionLeadMs") || parseFlagValue(rawArgs, "caption-lead-ms");
  const captionSound = parseFlagValue(rawArgs, "captionSound") || parseFlagValue(rawArgs, "caption-sound");
  const captionPlacement = parseFlagValue(rawArgs, "captionPlacement") || parseFlagValue(rawArgs, "caption-placement");
  const captionMargin = parseFlagValue(rawArgs, "captionMargin") || parseFlagValue(rawArgs, "caption-margin");
  const captionX = parseFlagValue(rawArgs, "captionX") || parseFlagValue(rawArgs, "caption-x");
  const captionY = parseFlagValue(rawArgs, "captionY") || parseFlagValue(rawArgs, "caption-y");
  const captionXRatio = parseFlagValue(rawArgs, "captionXRatio") || parseFlagValue(rawArgs, "caption-x-ratio") || parseFlagValue(rawArgs, "captionLeftRatio") || parseFlagValue(rawArgs, "caption-left-ratio");
  const captionYRatio = parseFlagValue(rawArgs, "captionYRatio") || parseFlagValue(rawArgs, "caption-y-ratio") || parseFlagValue(rawArgs, "captionTopRatio") || parseFlagValue(rawArgs, "caption-top-ratio");
  const sound = parseFlagValue(rawArgs, "sound") || parseFlagValue(rawArgs, "sfx");
  const trail = parseFlagValue(rawArgs, "trail") || parseFlagValue(rawArgs, "effect");
  const pathStyle = parseFlagValue(rawArgs, "pathStyle") || parseFlagValue(rawArgs, "path-style");
  const motion = parseFlagValue(rawArgs, "motion") || parseFlagValue(rawArgs, "easing") || parseFlagValue(rawArgs, "velocity");
  const trajectory = parseFlagValue(rawArgs, "trajectory") || parseFlagValue(rawArgs, "curve") || parseFlagValue(rawArgs, "arc");
  const glow = parseFlagValue(rawArgs, "glow") || parseFlagValue(rawArgs, "bloom");
  const idle = parseFlagValue(rawArgs, "idle") || parseFlagValue(rawArgs, "settle") || parseFlagValue(rawArgs, "presence");
  const edge = parseFlagValue(rawArgs, "edge") || parseFlagValue(rawArgs, "edgeEffect") || parseFlagValue(rawArgs, "edge-effect") || parseFlagValue(rawArgs, "arrival");

  if (!app && !name && method === "computer.launchApp" && positional[0]) {
    params.app = positional[0];
  }
  if (magicScout && !app && !name) {
    params.app = "Scout";
  }
  if (!text && (method === "computer.typeWindowText" || method === "computer.demoScout" || method === "computer.magicCursor")) {
    const targetApp = String(params.app || app || name || "");
    const messageOffset = targetApp && positional[0] === targetApp ? 1 : 0;
    const positionalText = positional.slice(messageOffset).join(" ").trim();
    if (positionalText) text = positionalText;
  }
  if (method === "computer.click" && !x && !y && positional.length >= 2) {
    const px = Number(positional[0]);
    const py = Number(positional[1]);
    if (Number.isFinite(px) && Number.isFinite(py)) {
      params.x = px;
      params.y = py;
    }
  }

  if (text) params.text = text;
  if (tty) params.tty = tty;
  if (app) params.app = app;
  if (name) params.name = name;
  if (bundleId) params.bundleId = bundleId;
  if (path) params.path = path;
  if (wid && Number.isFinite(Number(wid))) params.wid = Number(wid);
  if (terminalSessionId) params.terminalSessionId = terminalSessionId;
  if (session) params.session = session;
  if (title) params.title = title;
  if (treatment) params.treatment = treatment;
  if (transport) params.transport = transport;
  if (x && Number.isFinite(Number(x))) params.x = Number(x);
  if (y && Number.isFinite(Number(y))) params.y = Number(y);
  if (fromX && Number.isFinite(Number(fromX))) params.fromX = Number(fromX);
  if (fromY && Number.isFinite(Number(fromY))) params.fromY = Number(fromY);
  if (xRatio && Number.isFinite(Number(xRatio))) params.xRatio = Number(xRatio);
  if (yRatio && Number.isFinite(Number(yRatio))) params.yRatio = Number(yRatio);
  if (fromXRatio && Number.isFinite(Number(fromXRatio))) params.fromXRatio = Number(fromXRatio);
  if (fromYRatio && Number.isFinite(Number(fromYRatio))) params.fromYRatio = Number(fromYRatio);
  if (magicScout && params.xRatio === undefined) params.xRatio = 0.5;
  if (magicScout && params.yRatio === undefined) params.yRatio = 0.86;
  if (button) params.button = button;
  if (axLabel) params.axLabel = axLabel;
  if (appearance) params.appearance = appearance;
  if (shape) params.shape = shape;
  if (angleDeg && Number.isFinite(Number(angleDeg))) params.angleDeg = Number(angleDeg);
  if (size) params.size = size;
  if (color) params.color = color;
  if (durationMs && Number.isFinite(Number(durationMs))) params.durationMs = Number(durationMs);
  if (typeIntervalMs && Number.isFinite(Number(typeIntervalMs))) params.typeIntervalMs = Number(typeIntervalMs);
  if (label) params.label = label;
  if (caption) params.caption = caption;
  if (captionTitle) params.captionTitle = captionTitle;
  if (captionBody) params.captionBody = captionBody;
  if (captionTags) params.captionTags = captionTags;
  if (captionMode) params.captionMode = captionMode;
  if (captionEyebrow) params.captionEyebrow = captionEyebrow;
  if (captionLeadMs && Number.isFinite(Number(captionLeadMs))) params.captionLeadMs = Number(captionLeadMs);
  if (captionSound) params.captionSound = captionSound;
  if (captionPlacement) params.captionPlacement = captionPlacement;
  if (captionMargin && Number.isFinite(Number(captionMargin))) params.captionMargin = Number(captionMargin);
  if (captionX && Number.isFinite(Number(captionX))) params.captionX = Number(captionX);
  if (captionY && Number.isFinite(Number(captionY))) params.captionY = Number(captionY);
  if (captionXRatio && Number.isFinite(Number(captionXRatio))) params.captionXRatio = Number(captionXRatio);
  if (captionYRatio && Number.isFinite(Number(captionYRatio))) params.captionYRatio = Number(captionYRatio);
  if (sound) params.sound = sound;
  if (trail) params.trail = trail;
  if (pathStyle) params.pathStyle = pathStyle;
  if (motion) params.motion = motion;
  if (trajectory) params.trajectory = trajectory;
  if (glow) params.glow = glow;
  if (idle) params.idle = idle;
  if (edge) params.edge = edge;
  if (capture === "false" || capture === "0") params.capture = false;
  if (hasFlag(rawArgs, "no-capture") || hasFlag(rawArgs, "noCapture")) params.capture = false;
  if (hasFlag(rawArgs, "no-focus") || hasFlag(rawArgs, "noFocus") || hasFlag(rawArgs, "nofocus")) params.noFocus = true;
  if (hasFlag(rawArgs, "dry-run") || hasFlag(rawArgs, "dryRun")) params.dryRun = true;
  if (hasFlag(rawArgs, "enter")) params.enter = true;
  if (hasFlag(rawArgs, "send")) params.send = true;
  if (hasFlag(rawArgs, "append")) params.append = true;
  if (hasFlag(rawArgs, "show-caption") || hasFlag(rawArgs, "showCaption")) params.showCaption = true;
  if (hasFlag(rawArgs, "no-caption-selections") || hasFlag(rawArgs, "noCaptionSelections")) params.captionSelections = false;
  if (hasFlag(rawArgs, "typewriter") || hasFlag(rawArgs, "typing")) params.typewriter = true;
  if (hasFlag(rawArgs, "execute")) params.treatment = "execute";
  if (hasFlag(rawArgs, "present")) params.treatment = "present";
  if (hasFlag(rawArgs, "stage")) params.treatment = "stage";
  if (hasFlag(rawArgs, "observe")) params.treatment = "observe";
  if (hasFlag(rawArgs, "click")) params.click = true;

  await withDaemon(async ({ daemonCall }) => {
    let result: any;
    if (method === "computer.click" || method === "computer.magicCursor") {
      const cua = await import("./cua.ts");
      result = method === "computer.click"
        ? await cua.click(params as any)
        : await cua.magicCursor(params as any);
    } else {
      result = await daemonCall(method, params, 30000) as any;
    }
    if (jsonFlag) {
      console.log(JSON.stringify(result, null, 2));
      return;
    }

    const selected = result.selected || {};
    const terminal = selected.terminal || {};
    const target = result.target || terminal;
    const run = result.run || {};
    console.log(`${result.action || sub} ${result.treatment ? `(${result.treatment})` : ""}`);
    if (result.cursor) {
      console.log("  target: cursor");
    } else {
      console.log(`  target: ${target.app || result.app || "terminal"} ${terminal.tty || ""}${target.windowId || target.wid ? ` wid:${target.windowId || target.wid}` : ""}`);
    }
	    if (result.cursor) console.log(`  cursor: (${Math.round(result.cursor.x)}, ${Math.round(result.cursor.y)})`);
	    if (result.from) console.log(`  from: (${Math.round(result.from.x)}, ${Math.round(result.from.y)})`);
	    console.log(`  run: ${run.id || "?"}`);
    if (typeof result.launched === "boolean") console.log(`  launched: ${result.launched}`);
    if (typeof result.focused === "boolean") console.log(`  focused: ${result.focused}`);
    if (typeof result.clicked === "boolean") console.log(`  clicked: ${result.clicked}`);
    if (typeof result.shown === "boolean") console.log(`  shown: ${result.shown}`);
    if (result.button) console.log(`  button: ${result.button}`);
    if (result.appearance?.style) console.log(`  appearance: ${result.appearance.style}${result.appearance.color ? ` ${result.appearance.color}` : ""}${result.appearance.shape ? ` shape:${result.appearance.shape}` : ""}${result.appearance.angleDeg !== undefined ? ` angle:${result.appearance.angleDeg}` : ""}${result.appearance.size ? ` size:${result.appearance.size}` : ""}`);
    if (result.typedText !== undefined) console.log(`  typed: ${result.dryRun ? "dry run" : JSON.stringify(result.typedText || "")}`);
    if (result.transport) console.log(`  transport: ${result.transport}`);
    if (result.beforeArtifact?.path) console.log(`  before: ${result.beforeArtifact.path}`);
    if (result.afterArtifact?.path) console.log(`  after: ${result.afterArtifact.path}`);
  });
}

const VOICE_SUBCOMMANDS = new Set([
  "status", "say", "stop", "pause", "resume", "skip", "seek", "list", "select",
  "listen", "stopListening", "simulate", "sim", "intents",
]);

function voiceUsage(): void {
  console.log("Usage: lats voice <subcommand> [--json]\n");
  console.log("Speaking (Voice helper):");
  console.log('  say <text>        Speak text [--voice <id>] [--provider <id>] [--rate <n>]');
  console.log("  stop              Stop speaking and clear the queue");
  console.log("  pause | resume    Pause or resume the current job");
  console.log("  skip              Skip to the next queued job");
  console.log("  seek <seconds>    Seek the current job");
  console.log("  list              List voices");
  console.log("  select <voice>    Choose the default voice [--provider <id>]");
  console.log("\nListening (Lattices):");
  console.log("  listen            Start voice capture");
  console.log("  stopListening     Stop voice capture and run the transcript");
  console.log("  simulate <text>   Parse and execute a voice command [--dry-run]");
  console.log("  intents           List all available intents");
  console.log("  status            Listening state and Voice helper status");
  console.log("\nExamples:");
  console.log('  lats voice say "Build finished"');
  console.log('  lats voice simulate "tile this left"');
  console.log('  lats voice simulate "focus chrome" --dry-run');
}

function takeFlag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index === -1) return undefined;
  const value = args[index + 1];
  args.splice(index, value === undefined ? 1 : 2);
  return value;
}

function printVoiceQueue(status: any): void {
  const current = status?.current;
  if (current) {
    console.log(`Speaking: ${current.state} "${String(current.text ?? "").slice(0, 60)}"`);
  } else {
    console.log("Speaking: idle");
  }
  const queued = Array.isArray(status?.queued) ? status.queued.length : 0;
  if (queued) console.log(`Queued: ${queued}`);
  if (status?.failure?.error) console.log(`\x1b[31mFailure:\x1b[0m ${status.failure.error}`);
}

async function voiceCommand(subcommand?: string, ...rest: string[]): Promise<void> {
  if (!subcommand || !VOICE_SUBCOMMANDS.has(subcommand)) {
    voiceUsage();
    return;
  }

  const args = [...rest];
  const jsonOut = args.includes("--json");
  if (jsonOut) args.splice(args.indexOf("--json"), 1);
  const HELPER_TIMEOUT = 10000;

  const emit = (result: unknown, human: () => void) => {
    if (jsonOut) console.log(JSON.stringify(result, null, 2));
    else human();
  };

  if ((subcommand === "simulate" || subcommand === "sim") && !args.filter(a => a !== "--dry-run").join(" ")) {
    console.log("Usage: lats voice simulate <text>");
    return;
  }

  await withDaemon(async ({ daemonCall }) => {
    switch (subcommand) {
    case "status": {
      const status = await daemonCall("voice.status", null, HELPER_TIMEOUT) as any;
      emit(status, () => {
        console.log(`Provider: ${status.provider}`);
        console.log(`Available: ${status.available}`);
        console.log(`Listening: ${status.listening}`);
        if (status.lastTranscript) console.log(`Last: "${status.lastTranscript}"`);
        const helper = status.helper;
        if (helper) {
          if (helper.reachable) {
            console.log(`Voice helper: running`);
            printVoiceQueue(helper.status);
          } else {
            console.log(`Voice helper: ${helper.error ?? "unavailable"}`);
            if (helper.hint) console.log(`  ${helper.hint}`);
            else if (helper.message && helper.message !== helper.error) console.log(`  ${helper.message}`);
          }
        }
      });
      break;
    }
    case "say": {
      const voice = takeFlag(args, "--voice");
      const provider = takeFlag(args, "--provider");
      const rate = takeFlag(args, "--rate");
      const text = args.join(" ").trim();
      if (!text) {
        console.log('Usage: lats voice say <text> [--voice <id>] [--provider <id>] [--rate <n>]');
        return;
      }
      const params: Record<string, unknown> = { text, source: { kind: "cli", label: "lats voice say" } };
      if (voice) params.voice = voice;
      if (provider) params.provider = provider;
      if (rate) params.rate = Number(rate);
      const result = await daemonCall("voice.say", params, HELPER_TIMEOUT) as any;
      emit(result, () => console.log(`${result.state} ${result.id}`));
      break;
    }
    case "stop":
    case "pause":
    case "resume":
    case "skip": {
      const result = await daemonCall(`voice.${subcommand}`, null, HELPER_TIMEOUT);
      emit(result, () => printVoiceQueue(result));
      break;
    }
    case "seek": {
      const seconds = Number(args[0]);
      if (!Number.isFinite(seconds)) {
        console.log("Usage: lats voice seek <seconds>");
        return;
      }
      const result = await daemonCall("voice.seek", { seconds }, HELPER_TIMEOUT);
      emit(result, () => printVoiceQueue(result));
      break;
    }
    case "list": {
      const voices = await daemonCall("voice.list", null, HELPER_TIMEOUT) as any[];
      emit(voices, () => {
        for (const v of voices) {
          const marks = [v.default ? "default" : "", v.available ? "" : "unavailable"].filter(Boolean).join(", ");
          console.log(`  ${v.provider.padEnd(11)} ${v.id}  ${v.label}${marks ? `  (${marks})` : ""}`);
        }
      });
      break;
    }
    case "select": {
      const provider = takeFlag(args, "--provider");
      const voice = args.join(" ").trim();
      if (!voice) {
        console.log("Usage: lats voice select <voice> [--provider <id>]");
        return;
      }
      const params: Record<string, unknown> = { voice };
      if (provider) params.provider = provider;
      const result = await daemonCall("voice.select", params, HELPER_TIMEOUT);
      emit(result, () => console.log(`Selected ${voice}${provider ? ` for ${provider}` : ""}`));
      break;
    }
    case "listen": {
      const result = await daemonCall("voice.listen") as any;
      emit(result, () => console.log(`Listening (${result.provider})`));
      break;
    }
    case "stopListening": {
      const result = await daemonCall("voice.stopListening");
      emit(result, () => console.log("Stopped listening"));
      break;
    }
    case "simulate":
    case "sim": {
      const execute = !args.includes("--dry-run");
      const cleanText = args.filter(r => r !== "--dry-run").join(" ");
      const result = await daemonCall("voice.simulate", { text: cleanText, execute }, 15000) as any;
      if (jsonOut) {
        console.log(JSON.stringify(result, null, 2));
        return;
      }
      if (!result.parsed) {
        console.log(`\x1b[33mNo match:\x1b[0m "${cleanText}"`);
        return;
      }
      const slots = Object.entries(result.slots || {}).map(([k,v]) => `${k}: ${v}`).join(", ");
      const conf = result.confidence ? ` (${(result.confidence * 100).toFixed(0)}%)` : "";
      console.log(`\x1b[36m${result.intent}\x1b[0m${slots ? `  ${slots}` : ""}${conf}`);
      if (result.executed) {
        console.log(`\x1b[32mExecuted\x1b[0m`);
      } else if (result.error) {
        console.log(`\x1b[31mError:\x1b[0m ${result.error}`);
      }
      break;
    }
    case "intents": {
      const intents = await daemonCall("intents.list") as any[];
      if (jsonOut) {
        console.log(JSON.stringify(intents, null, 2));
        return;
      }
      for (const intent of intents) {
        const slots = intent.slots.map((s: any) => `${s.name}:${s.type}${s.required ? "*" : ""}`).join(", ");
        console.log(`  \x1b[1m${intent.intent}\x1b[0m  ${intent.description}`);
        if (slots) console.log(`    slots: ${slots}`);
        console.log(`    e.g. "${intent.examples[0]}"`);
        console.log();
      }
      break;
    }
    }
  });
}

async function assistantCommand(subcommand?: string, ...rest: string[]): Promise<void> {
  if (subcommand !== "plan") {
    console.log("Usage: lats assistant plan <text> [--json]");
    return;
  }

  const jsonOut = rest.includes("--json");
  const text = rest.filter((arg) => arg !== "--json").join(" ").trim();
  if (!text) {
    console.log("Usage: lats assistant plan <text> [--json]");
    return;
  }

  const { tryLocalAssistantPlan } = await import("./assistant-intelligence.ts");
  const result = tryLocalAssistantPlan(text) ?? {
    actions: [],
    spoken: "No local TS plan matched.",
    _meta: { source: "local-rule", matched: false },
  };

  if (jsonOut) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  console.log(result.spoken);
}

async function callCommand(method?: string, ...rest: string[]): Promise<void> {
  if (!method) {
    console.log("Usage: lats call <method> [params-json]");
    console.log("\nExamples:");
    console.log("  lats call daemon.status");
    console.log("  lats call api.schema");
    console.log('  lats call windows.place \'{"session":"vox","placement":"left"}\'');
    return;
  }
  await withDaemon(async ({ daemonCall }) => {
    const params = rest[0] ? JSON.parse(rest[0]) : null;
    const relocationMethods = new Set([
      "windows.move", "windows.place", "actions.execute", "history.undo",
      "window.move", "window.place", "actions.undo",
    ]);
    const result = await daemonCall(method, params, relocationMethods.has(method) ? 60_000 : 15_000);
    console.log(JSON.stringify(result, null, 2));
  });
}

interface AppActorAsset {
  id: string;
  appName: string;
  appPath: string;
  bundleIdentifier?: string;
  iconPath: string;
  assetDir: string;
}

function plistValue(plistPath: string, key: string): string | undefined {
  const value = runQuiet(`/usr/libexec/PlistBuddy -c 'Print :${esc(key)}' '${esc(plistPath)}' 2>/dev/null`);
  return value?.trim() || undefined;
}

function resolveApplication(appQuery: string): string | undefined {
  const directPath = appQuery.endsWith(".app") ? resolve(appQuery) : undefined;
  if (directPath && existsSync(directPath)) return directPath.replace(/\/$/, "");

  const script = `POSIX path of (path to application "${appleScriptString(appQuery.replace(/\.app$/i, ""))}")`;
  const fromLaunchServices = runQuiet(`osascript -e '${esc(script)}' 2>/dev/null`);
  if (fromLaunchServices) return fromLaunchServices.trim().replace(/\/$/, "");

  const appName = appQuery.endsWith(".app") ? appQuery : `${appQuery}.app`;
  const fromFind = runQuiet(
    `find /Applications /System/Applications '${esc(resolve(homedir(), "Applications"))}' -maxdepth 5 -iname '${esc(appName)}' -print -quit 2>/dev/null`
  );
  return fromFind?.trim().replace(/\/$/, "") || undefined;
}

function resolveApplicationByBundleIdentifier(bundleIdentifier: string): string | undefined {
  const script = `POSIX path of (path to application id "${appleScriptString(bundleIdentifier)}")`;
  const fromLaunchServices = runQuiet(`osascript -e '${esc(script)}' 2>/dev/null`);
  return fromLaunchServices?.trim().replace(/\/$/, "") || undefined;
}

function iconPathForApplication(appPath: string): string | undefined {
  const resourcesDir = resolve(appPath, "Contents", "Resources");
  const infoPlist = resolve(appPath, "Contents", "Info.plist");
  const iconFile = plistValue(infoPlist, "CFBundleIconFile");
  const candidates: string[] = [];
  if (iconFile) {
    candidates.push(resolve(resourcesDir, iconFile));
    if (!/\.[a-z0-9]+$/i.test(iconFile)) {
      candidates.push(resolve(resourcesDir, `${iconFile}.icns`));
    }
  }
  candidates.push(
    resolve(resourcesDir, "AppIcon.icns"),
    resolve(resourcesDir, "icon.icns"),
    resolve(resourcesDir, "electron.icns")
  );
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  const firstIcns = runQuiet(`find '${esc(resourcesDir)}' -maxdepth 1 -iname '*.icns' -print -quit 2>/dev/null`);
  return firstIcns?.trim() || undefined;
}

function ensureAppActorAsset(appQuery: string): AppActorAsset {
  const appPath = resolveApplication(appQuery);
  if (!appPath) {
    throw new Error(`Could not find application: ${appQuery}`);
  }

  const appName = basename(appPath, ".app");
  const iconPath = iconPathForApplication(appPath);
  if (!iconPath) {
    throw new Error(`Could not find an icon resource in ${appPath}`);
  }

  const id = `${slugify(appName)}-icon`;
  const assetDir = resolve(homedir(), ".codex", "pets", id);
  const spritesheetPath = resolve(assetDir, "spritesheet.png");
  mkdirSync(assetDir, { recursive: true });
  run(`sips -s format png -Z 192 '${esc(iconPath)}' --out '${esc(spritesheetPath)}' >/dev/null`);

  const metadata = {
    id,
    displayName: `${appName} Icon`,
    description: `A one-frame overlay actor made from the ${appName} application icon.`,
    spritesheetPath: "spritesheet.png",
    states: {
      idle: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      thinking: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      working: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      listening: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      waiting: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      ready: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
    },
  };
  writeFileSync(resolve(assetDir, "pet.json"), `${JSON.stringify(metadata, null, 2)}\n`);

  const bundleIdentifier = plistValue(resolve(appPath, "Contents", "Info.plist"), "CFBundleIdentifier");
  return { id, appName, appPath, bundleIdentifier, iconPath, assetDir };
}

function ensureIconActorAsset(idSeed: string, displayName: string, iconPath: string): string {
  if (!existsSync(iconPath)) {
    throw new Error(`HUD icon does not exist: ${iconPath}`);
  }

  const id = `${slugify(idSeed)}-hud-icon`;
  const assetDir = resolve(homedir(), ".codex", "pets", id);
  const spritesheetPath = resolve(assetDir, "spritesheet.png");
  mkdirSync(assetDir, { recursive: true });
  run(`sips -s format png -Z 192 '${esc(iconPath)}' --out '${esc(spritesheetPath)}' >/dev/null`);

  const metadata = {
    id,
    displayName: `${displayName} HUD Icon`,
    description: `A one-frame overlay actor icon for the ${displayName} HUD.`,
    spritesheetPath: "spritesheet.png",
    states: {
      idle: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      thinking: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      working: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      listening: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      waiting: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
      ready: { row: 0, frames: 1, frameWidth: 192, frameHeight: 192 },
    },
  };
  writeFileSync(resolve(assetDir, "pet.json"), `${JSON.stringify(metadata, null, 2)}\n`);
  return id;
}

function actorUsage(): void {
  console.log(`Usage:
  lats actor app <app-name> [message] [--state=idle] [--x=520 --y=340] [--show-label]
  lats actor switcher [app-name ...] [--x=420 --y=220 --gap=270] [--show-label]
  lats actor hud <actor-id> <url> [--hud-width=360 --hud-height=240]
  lats actor show|hide|toggle|status

Examples:
  lats actor app Codex "Building the release"
  lats actor app Talkie "Hover for latest state" --hud-url=http://localhost:5173
  lats actor hud switch-talkie http://localhost:5173
  lats actor switcher Codex Talkie
  lats actor toggle
  lats actor switcher "Google Chrome" Codex Talkie --show-label --scale=0.8
`);
}

async function actorCommand(sub?: string, ...rest: string[]): Promise<void> {
  if (sub === "app") {
    await actorAppCommand(rest);
    return;
  }
  if (sub === "switcher") {
    await actorSwitcherCommand(rest);
    return;
  }
  if (sub === "hud") {
    await actorHUDCommand(rest);
    return;
  }
  if (sub === "show" || sub === "hide" || sub === "toggle" || sub === "status") {
    await actorVisibilityCommand(sub, rest);
    return;
  }
  actorUsage();
}

function actorHUDOptions(rest: string[]): Record<string, unknown> {
  const hudUrl = parseFlagValue(rest, "hud-url") || parseFlagValue(rest, "hudUrl");
  const hudHTML = parseFlagValue(rest, "hud-html") || parseFlagValue(rest, "hudHTML") || parseFlagValue(rest, "hudHtml");
  const hudTitle = parseFlagValue(rest, "hud-title") || parseFlagValue(rest, "hudTitle");
  const hudWidth = parseFlagValue(rest, "hud-width") || parseFlagValue(rest, "hudWidth") || parseFlagValue(rest, "width");
  const hudHeight = parseFlagValue(rest, "hud-height") || parseFlagValue(rest, "hudHeight") || parseFlagValue(rest, "height");
  return {
    ...(hudUrl ? { hudUrl } : {}),
    ...(hudHTML ? { hudHTML } : {}),
    ...(hudTitle ? { hudTitle } : {}),
    ...(hudWidth ? { hudWidth: Number(hudWidth) } : {}),
    ...(hudHeight ? { hudHeight: Number(hudHeight) } : {}),
  };
}

function shouldHideActorLabel(rest: string[]): boolean {
  if (hasFlag(rest, "show-label") || hasFlag(rest, "showLabel")) return false;
  return true;
}

async function actorHUDCommand(rest: string[]): Promise<void> {
  const positional = nonFlagArgs(rest);
  const id = positional[0];
  if (!id) {
    actorUsage();
    return;
  }

  const url = positional[1];
  const clear = hasFlag(rest, "clear");
  await withDaemon(async ({ daemonCall }) => {
    const result = await daemonCall("overlay.actor.hud", {
      id,
      clear,
      ...(url && !clear ? { hudUrl: url } : {}),
      ...actorHUDOptions(rest),
    }, 15000) as any;

    if (hasFlag(rest, "json")) {
      console.log(JSON.stringify(result, null, 2));
    } else if (clear) {
      console.log(`Cleared HUD for ${id}.`);
    } else {
      console.log(`Attached hover HUD to ${id}.`);
    }
  });
}

async function actorVisibilityCommand(action: string, rest: string[]): Promise<void> {
  await withDaemon(async ({ daemonCall }) => {
    const result = await daemonCall("overlay.actor.visibility", {
      action,
      feedback: !hasFlag(rest, "quiet") && action !== "status",
    }, 15000) as any;

    if (hasFlag(rest, "json")) {
      console.log(JSON.stringify(result, null, 2));
      return;
    }

    const state = result.visible ? "shown" : "hidden";
    const count = Number(result.actorCount ?? 0);
    console.log(`Actor layer ${state} (${count} actor${count === 1 ? "" : "s"}).`);
  });
}

async function actorAppCommand(rest: string[]): Promise<void> {
  const positional = nonFlagArgs(rest);
  const appQuery = positional[0];
  if (!appQuery) {
    actorUsage();
    return;
  }
  const message = positional.slice(1).join(" ") || `Tap to switch to ${appQuery}.`;
  await withDaemon(async ({ daemonCall }) => {
    const asset = ensureAppActorAsset(appQuery);
    const id = parseFlagValue(rest, "id") || `app-${slugify(asset.appName)}`;
    const state = parseFlagValue(rest, "state") || "idle";
    const ttlMs = Number(parseFlagValue(rest, "ttl") || parseFlagValue(rest, "ttlMs") || 0);
    const x = Number(parseFlagValue(rest, "x") || 520);
    const y = Number(parseFlagValue(rest, "y") || 340);
    const placement = parseFlagValue(rest, "placement") || "point";
    const style = parseFlagValue(rest, "style") || "playful";
    const dismissible = hasFlag(rest, "dismissible");
    const labelHidden = shouldHideActorLabel(rest);
    const closeOnActivate = hasFlag(rest, "close-on-activate") || hasFlag(rest, "closeOnActivate");
    const scale = Number(parseFlagValue(rest, "scale") || 1);

    const result = await daemonCall("overlay.actor.publish", {
      id,
      renderer: "sprite",
      asset: asset.id,
      state,
      name: parseFlagValue(rest, "name") || asset.appName,
      message,
      placement,
      x,
      y,
      style,
      ttlMs,
      dismissible,
      labelHidden,
      closeOnActivate,
      scale,
      ...actorHUDOptions(rest),
      targetApp: asset.appName,
      targetBundleId: asset.bundleIdentifier,
      targetAppPath: asset.appPath,
    }, 15000) as any;

    if (!hasFlag(rest, "no-move")) {
      await daemonCall("overlay.actor.moveTo", {
        id,
        x: x + 40,
        y: y + 50,
        durationMs: 700,
        easing: "spring",
      }, 15000);
    }

    if (hasFlag(rest, "json")) {
      console.log(JSON.stringify({ ...result, asset: asset.id, appPath: asset.appPath }, null, 2));
    } else {
      console.log(`Published ${asset.appName} actor (${id}). Click it to switch to ${asset.appName}.`);
    }
  });
}

async function actorSwitcherCommand(rest: string[]): Promise<void> {
  const appNames = nonFlagArgs(rest);
  const apps = appNames.length ? appNames : ["Codex", "Talkie"];
  await withDaemon(async ({ daemonCall }) => {
    const startX = Number(parseFlagValue(rest, "x") || 420);
    const y = Number(parseFlagValue(rest, "y") || 220);
    const gap = Number(parseFlagValue(rest, "gap") || 270);
    const ttlMs = Number(parseFlagValue(rest, "ttl") || parseFlagValue(rest, "ttlMs") || 0);
    const style = parseFlagValue(rest, "style") || "info";
    const dismissible = hasFlag(rest, "dismissible");
    const labelHidden = shouldHideActorLabel(rest);
    const closeOnActivate = hasFlag(rest, "close-on-activate") || hasFlag(rest, "closeOnActivate");
    const scale = Number(parseFlagValue(rest, "scale") || 1);
    const results: any[] = [];

    for (let i = 0; i < apps.length; i++) {
      const asset = ensureAppActorAsset(apps[i]);
      const id = `switch-${slugify(asset.appName)}`;
      const x = startX + i * gap;
      const result = await daemonCall("overlay.actor.publish", {
        id,
        renderer: "sprite",
        asset: asset.id,
        state: "ready",
        name: asset.appName,
        message: `Tap to switch to ${asset.appName}.`,
        placement: "point",
        x,
        y,
        style,
        ttlMs,
        dismissible,
        labelHidden,
        closeOnActivate,
        scale,
        ...actorHUDOptions(rest),
        targetApp: asset.appName,
        targetBundleId: asset.bundleIdentifier,
        targetAppPath: asset.appPath,
      }, 15000) as any;
      results.push({ ...result, asset: asset.id, appPath: asset.appPath });
      await daemonCall("overlay.actor.moveTo", {
        id,
        x: x + 28,
        y: y + 36,
        durationMs: 650,
        easing: "spring",
      }, 15000);
    }

    if (hasFlag(rest, "json")) {
      console.log(JSON.stringify(results, null, 2));
    } else {
      console.log(`Published app switcher for ${apps.join(", ")}.`);
    }
  });
}

type HUDPathField = string | {
  path?: string;
  format?: string;
  schema?: string;
  presentation?: string;
  title?: string;
  description?: string;
  pollMs?: number;
};

interface HUDManifest {
  version?: number;
  manifestVersion?: number;
  id?: string;
  name?: string;
  bundleId?: string;
  bundleIdentifier?: string;
  app?: string;
  appPath?: string;
  icon?: string;
  entry?: string;
  readAccess?: string | string[];
  state?: HUDPathField;
  events?: HUDPathField | HUDPathField[];
  log?: HUDPathField;
  logs?: HUDPathField[];
  sources?: HUDPathField[] | Record<string, HUDPathField>;
  surface?: {
    width?: number;
    height?: number;
    title?: string;
    transparent?: boolean;
  };
  actor?: {
    id?: string;
    message?: string;
    state?: string;
    x?: number;
    y?: number;
    placement?: string;
    style?: string;
    scale?: number;
    labelHidden?: boolean;
    closeOnActivate?: boolean;
    click?: string | { type?: string };
  };
}

interface ResolvedHUDManifest {
  manifestPath: string;
  rootDir: string;
  manifest: HUDManifest;
  id: string;
  name: string;
  entry: string;
  iconPath?: string;
  appPath?: string;
  bundleIdentifier?: string;
  readAccessPath?: string;
}

interface HUDRegistryEntry {
  id: string;
  name?: string;
  bundleIdentifier?: string;
  manifestPath: string;
  registeredAt: string;
  lastPublishedAt?: string;
}

interface HUDRegistry {
  version: 1;
  entries: HUDRegistryEntry[];
}

function hudUsage(): void {
  console.log(`Usage:
  lats hud register [manifest] [--publish]   Register .lattices/hud/manifest.json
  lats hud publish [manifest-or-id]          Publish one HUD actor now
  lats hud sync                              Publish all registered HUD actors
  lats hud list                              List registered HUDs
  lats hud discover [root] [--register]      Find HUD manifests under a folder

Manifest:
  .lattices/hud/manifest.json

Examples:
  lats hud register .lattices/hud/manifest.json --publish
  lats hud publish talkie --x=520 --y=340
  lats hud sync
`);
}

function hudRegistryPath(): string {
  return resolve(homedir(), ".lattices", "huds.json");
}

function readHUDRegistry(): HUDRegistry {
  const path = hudRegistryPath();
  if (!existsSync(path)) return { version: 1, entries: [] };
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<HUDRegistry>;
    return {
      version: 1,
      entries: Array.isArray(parsed.entries) ? parsed.entries : [],
    };
  } catch (e: unknown) {
    throw new Error(`Invalid HUD registry ${path}: ${(e as Error).message}`);
  }
}

function writeHUDRegistry(registry: HUDRegistry): void {
  const path = hudRegistryPath();
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(registry, null, 2)}\n`);
}

function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function isURLLike(value: string): boolean {
  return /^[a-z][a-z0-9+.-]*:/i.test(value);
}

function resolveHUDPath(rootDir: string, value: HUDPathField | undefined, fallback?: string): string | undefined {
  const raw = typeof value === "string" ? value : value?.path;
  const path = raw || fallback;
  if (!path) return undefined;
  if (isURLLike(path)) return path;
  if (path.startsWith("~/")) return resolve(homedir(), path.slice(2));
  return isAbsolute(path) ? path : resolve(rootDir, path);
}

function resolveHUDReadAccess(rootDir: string, manifest: HUDManifest, rest: string[] = []): string {
  const flagValue = parseFlagValue(rest, "read-access") || parseFlagValue(rest, "readAccess");
  const declared = flagValue
    ?? (Array.isArray(manifest.readAccess) ? manifest.readAccess[0] : manifest.readAccess);
  if (!declared) return rootDir;
  if (isURLLike(declared)) return rootDir;
  if (declared.startsWith("~/")) return resolve(homedir(), declared.slice(2));
  return isAbsolute(declared) ? declared : resolve(rootDir, declared);
}

function resolveHUDManifestInput(input?: string): string {
  if (!input) {
    const defaultPath = resolve(process.cwd(), ".lattices", "hud", "manifest.json");
    if (existsSync(defaultPath)) return defaultPath;
    throw new Error("No manifest provided and .lattices/hud/manifest.json was not found.");
  }

  const candidate = resolve(input);
  if (existsSync(candidate)) {
    return isDirectory(candidate) ? resolve(candidate, "manifest.json") : candidate;
  }

  const registry = readHUDRegistry();
  const entry = registry.entries.find((item) => item.id === input);
  if (entry) return entry.manifestPath;

  throw new Error(`HUD manifest or registered id not found: ${input}`);
}

function readHUDManifest(input?: string): ResolvedHUDManifest {
  const manifestPath = resolveHUDManifestInput(input);
  if (!existsSync(manifestPath)) {
    throw new Error(`HUD manifest does not exist: ${manifestPath}`);
  }

  const rootDir = dirname(manifestPath);
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as HUDManifest;
  const id = manifest.actor?.id || manifest.id;
  if (!id) throw new Error(`HUD manifest is missing id: ${manifestPath}`);

  const name = manifest.name || id;
  const entry = resolveHUDPath(rootDir, manifest.entry, "./index.html");
  if (!entry) throw new Error(`HUD manifest is missing entry: ${manifestPath}`);
  if (!isURLLike(entry) && !existsSync(entry)) {
    throw new Error(`HUD entry does not exist: ${entry}`);
  }

  const iconPath = resolveHUDPath(rootDir, manifest.icon);
  const appPath = resolveHUDPath(rootDir, manifest.appPath)
    ?? (manifest.bundleId || manifest.bundleIdentifier
      ? resolveApplicationByBundleIdentifier(manifest.bundleId || manifest.bundleIdentifier || "")
      : undefined)
    ?? (manifest.app ? resolveApplication(manifest.app) : undefined);
  const bundleIdentifier = manifest.bundleId
    ?? manifest.bundleIdentifier
    ?? (appPath ? plistValue(resolve(appPath, "Contents", "Info.plist"), "CFBundleIdentifier") : undefined);

  return {
    manifestPath,
    rootDir,
    manifest,
    id,
    name,
    entry,
    iconPath: iconPath && !isURLLike(iconPath) ? iconPath : undefined,
    appPath: appPath && !isURLLike(appPath) ? appPath : undefined,
    bundleIdentifier,
    readAccessPath: resolveHUDReadAccess(rootDir, manifest),
  };
}

function numberFlag(rest: string[], name: string, fallback: number): number {
  const raw = parseFlagValue(rest, name);
  if (!raw) return fallback;
  const value = Number(raw);
  return Number.isFinite(value) ? value : fallback;
}

function numberFlagAny(rest: string[], names: string[], fallback: number): number {
  for (const name of names) {
    const raw = parseFlagValue(rest, name);
    if (!raw) continue;
    const value = Number(raw);
    if (Number.isFinite(value)) return value;
  }
  return fallback;
}

function hudActorAsset(resolved: ResolvedHUDManifest): string | undefined {
  if (resolved.iconPath) {
    return ensureIconActorAsset(resolved.id, resolved.name, resolved.iconPath);
  }

  const appQuery = resolved.appPath || resolved.manifest.app;
  if (!appQuery) return undefined;

  try {
    return ensureAppActorAsset(appQuery).id;
  } catch {
    return undefined;
  }
}

function hudClickType(manifest: HUDManifest): string {
  const click = manifest.actor?.click;
  if (!click) return "activateApp";
  return typeof click === "string" ? click : click.type || "activateApp";
}

function hudPublishPayload(resolved: ResolvedHUDManifest, rest: string[], index = 0): Record<string, unknown> {
  const manifest = resolved.manifest;
  const actor = manifest.actor ?? {};
  const surface = manifest.surface ?? {};
  const targetEnabled = hudClickType(manifest) !== "none";
  const asset = hudActorAsset(resolved);
  const x = numberFlag(rest, "x", actor.x ?? 420 + index * 112);
  const y = numberFlag(rest, "y", actor.y ?? 220);

  return {
    id: resolved.id,
    renderer: "sprite",
    ...(asset ? { asset } : {}),
    state: parseFlagValue(rest, "state") || actor.state || "ready",
    name: parseFlagValue(rest, "name") || resolved.name,
    message: actor.message || `Hover for ${resolved.name} status.`,
    placement: parseFlagValue(rest, "placement") || actor.placement || "point",
    x,
    y,
    style: parseFlagValue(rest, "style") || actor.style || "info",
    labelHidden: actor.labelHidden ?? true,
    closeOnActivate: actor.closeOnActivate ?? false,
    scale: numberFlag(rest, "scale", actor.scale ?? 1),
    hudUrl: resolved.entry,
    hudTitle: surface.title || resolved.name,
    hudWidth: numberFlagAny(rest, ["hud-width", "hudWidth", "width"], surface.width ?? 380),
    hudHeight: numberFlagAny(rest, ["hud-height", "hudHeight", "height"], surface.height ?? 260),
    hudReadAccess: resolveHUDReadAccess(resolved.rootDir, manifest, rest),
    ...(targetEnabled && resolved.bundleIdentifier ? { targetBundleId: resolved.bundleIdentifier } : {}),
    ...(targetEnabled && resolved.appPath ? { targetAppPath: resolved.appPath } : {}),
    ...(targetEnabled && manifest.app ? { targetApp: manifest.app } : {}),
  };
}

function upsertHUDRegistryEntry(resolved: ResolvedHUDManifest, published = false): HUDRegistryEntry {
  const registry = readHUDRegistry();
  const now = new Date().toISOString();
  const existing = registry.entries.find((entry) => entry.id === resolved.id);
  const next: HUDRegistryEntry = {
    id: resolved.id,
    name: resolved.name,
    bundleIdentifier: resolved.bundleIdentifier,
    manifestPath: resolved.manifestPath,
    registeredAt: existing?.registeredAt ?? now,
    lastPublishedAt: published ? now : existing?.lastPublishedAt,
  };
  registry.entries = [
    next,
    ...registry.entries.filter((entry) => entry.id !== resolved.id),
  ].sort((a, b) => a.id.localeCompare(b.id));
  writeHUDRegistry(registry);
  return next;
}

async function publishHUDManifest(resolved: ResolvedHUDManifest, rest: string[], index = 0): Promise<Record<string, unknown>> {
  return withDaemon(async ({ daemonCall }) => {
    const payload = hudPublishPayload(resolved, rest, index);
    const result = await daemonCall("overlay.actor.publish", payload, 15000) as Record<string, unknown>;
    if (!hasFlag(rest, "no-move")) {
      await daemonCall("overlay.actor.moveTo", {
        id: resolved.id,
        x: Number(payload.x) + 24,
        y: Number(payload.y) + 30,
        durationMs: 600,
        easing: "spring",
      }, 15000);
    }
    upsertHUDRegistryEntry(resolved, true);
    return result;
  });
}

async function hudRegisterCommand(rest: string[]): Promise<void> {
  const manifestArg = nonFlagArgs(rest)[0] || parseFlagValue(rest, "manifest");
  const resolved = readHUDManifest(manifestArg);
  const entry = upsertHUDRegistryEntry(resolved, false);

  if (hasFlag(rest, "publish")) {
    await publishHUDManifest(resolved, rest);
  }

  const published = hasFlag(rest, "publish");
  if (hasFlag(rest, "json")) {
    console.log(JSON.stringify(entry, null, 2));
  } else {
    console.log(`${published ? "Registered and published" : "Registered"} HUD ${resolved.id} -> ${resolved.manifestPath}`);
  }
}

async function hudPublishCommand(rest: string[]): Promise<void> {
  const manifestArg = nonFlagArgs(rest)[0] || parseFlagValue(rest, "manifest");
  const resolved = readHUDManifest(manifestArg);
  const result = await publishHUDManifest(resolved, rest);

  if (hasFlag(rest, "json")) {
    console.log(JSON.stringify({ ...result, manifestPath: resolved.manifestPath }, null, 2));
  } else {
    console.log(`Published HUD actor ${resolved.id}. Hover it for ${resolved.name}.`);
  }
}

async function hudSyncCommand(rest: string[]): Promise<void> {
  const registry = readHUDRegistry();
  const results: Record<string, unknown>[] = [];
  for (let i = 0; i < registry.entries.length; i++) {
    const resolved = readHUDManifest(registry.entries[i].id);
    results.push(await publishHUDManifest(resolved, rest, i));
  }

  if (hasFlag(rest, "json")) {
    console.log(JSON.stringify(results, null, 2));
  } else {
    console.log(`Published ${results.length} registered HUD actor${results.length === 1 ? "" : "s"}.`);
  }
}

function hudListCommand(rest: string[]): void {
  const registry = readHUDRegistry();
  if (hasFlag(rest, "json")) {
    console.log(JSON.stringify(registry, null, 2));
    return;
  }
  if (!registry.entries.length) {
    console.log("No registered HUDs. Run lats hud register .lattices/hud/manifest.json");
    return;
  }
  console.log("Registered HUDs:\n");
  for (const entry of registry.entries) {
    console.log(`  ${entry.id}${entry.name ? ` (${entry.name})` : ""}`);
    console.log(`    manifest: ${entry.manifestPath}`);
    if (entry.bundleIdentifier) console.log(`    bundle:   ${entry.bundleIdentifier}`);
    if (entry.lastPublishedAt) console.log(`    shown:    ${entry.lastPublishedAt}`);
    console.log();
  }
}

function hudDiscoverCommand(rest: string[]): void {
  const root = resolve(nonFlagArgs(rest)[0] || parseFlagValue(rest, "root") || process.cwd());
  const maxDepth = Number(parseFlagValue(rest, "max-depth") || parseFlagValue(rest, "maxDepth") || 6);
  const out = runQuiet(`find '${esc(root)}' -maxdepth ${maxDepth} -path '*/.lattices/hud/manifest.json' -print 2>/dev/null`);
  const manifests = out ? out.split("\n").filter(Boolean) : [];

  if (hasFlag(rest, "register")) {
    for (const manifestPath of manifests) {
      upsertHUDRegistryEntry(readHUDManifest(manifestPath), false);
    }
  }

  if (hasFlag(rest, "json")) {
    console.log(JSON.stringify(manifests, null, 2));
    return;
  }

  if (!manifests.length) {
    console.log(`No HUD manifests found under ${root}`);
    return;
  }
  for (const manifestPath of manifests) console.log(manifestPath);
  if (hasFlag(rest, "register")) {
    console.log(`\nRegistered ${manifests.length} HUD manifest${manifests.length === 1 ? "" : "s"}.`);
  }
}

async function hudCommand(sub?: string, ...rest: string[]): Promise<void> {
  try {
    switch (sub) {
    case "register":
      await hudRegisterCommand(rest);
      return;
    case "publish":
    case "show":
      await hudPublishCommand(rest);
      return;
    case "sync":
      await hudSyncCommand(rest);
      return;
    case "list":
    case "ls":
      hudListCommand(rest);
      return;
    case "discover":
      hudDiscoverCommand(rest);
      return;
    default:
      hudUsage();
    }
  } catch (e: unknown) {
    console.log(`Error: ${(e as Error).message}`);
  }
}

async function diagCommand(limit?: string): Promise<void> {
  await withDaemon(async ({ daemonCall }) => {
    const result = await daemonCall("diagnostics.list", { limit: parseInt(limit || "", 10) || 40 }) as any;
    if (!result.entries || !result.entries.length) {
      console.log("No diagnostic entries.");
      return;
    }
    for (const entry of result.entries) {
      const icon = entry.level === "success" ? "\x1b[32m✓\x1b[0m" :
                   entry.level === "warning" ? "\x1b[33m⚠\x1b[0m" :
                   entry.level === "error"   ? "\x1b[31m✗\x1b[0m" : "›";
      console.log(`  \x1b[90m${entry.time}\x1b[0m ${icon} ${entry.message}`);
    }
  });
}

async function distributeCommand(rawArgs: string[] = []): Promise<void> {
  const request = parseSpaceOptimizeArgs(rawArgs, "visible");
  await optimizeWindowsCommand(request, "Distributed");
}

async function tileFamilyCommand(rawArgs: string[]): Promise<void> {
  const request = parseSpaceOptimizeArgs(rawArgs, "active-app");
  await optimizeWindowsCommand(request, "Smart-tiled");
}

async function daemonLsCommand(): Promise<boolean> {
  const handled = await tryDaemon(async ({ daemonCall }) => {
    const sessions = await daemonCall("tmux.list") as any[];
    if (!sessions.length) {
      console.log("No active sessions.");
      return;
    }

    // Annotate sessions with workspace group info
    const ws = readWorkspaceConfig();
    const sessionGroupMap = new Map<string, { group: string; tab: string }>();
    if (ws?.groups) {
      for (const g of ws.groups) {
        for (const tab of g.tabs || []) {
          if (!tab.path) continue;
          const tabSession = toSessionName(resolve(tab.path));
          sessionGroupMap.set(tabSession, {
            group: g.label || g.id,
            tab: tabLabel(tab),
          });
        }
      }
    }

    console.log("Sessions:\n");
    for (const s of sessions) {
      const info = sessionGroupMap.get(s.name);
      const groupTag = info ? `  \x1b[36m[${info.group}: ${info.tab}]\x1b[0m` : "";
      const attachTag = s.attached ? "  \x1b[33m[attached]\x1b[0m" : "";
      console.log(`  ${s.name}  (${s.windowCount} windows)${attachTag}${groupTag}`);
    }
  });
  return handled !== null;
}

async function daemonStatusInventory(): Promise<boolean> {
  const handled = await tryDaemon(async ({ daemonCall }) => {
    const inv = await daemonCall("tmux.list", { includeOrphans: true }) as any;

    // Build managed session name set
    const managed = new Map<string, string>();
    const ws = readWorkspaceConfig();
    if (ws?.groups) {
      for (const g of ws.groups) {
        for (const tab of g.tabs || []) {
          if (!tab.path) continue;
          const name = toSessionName(resolve(tab.path));
          const label = `${g.label || g.id}: ${tabLabel(tab)}`;
          managed.set(name, label);
        }
      }
    }
    for (const s of inv.all) {
      if (!managed.has(s.name)) {
        // Check if it matches a scanned project (via daemon)
        const projects = await daemonCall("projects.list") as any[];
        for (const p of projects) {
          managed.set(p.sessionName, p.name);
        }
        break;
      }
    }

    const managedSessions = inv.all.filter((s: any) => managed.has(s.name));
    const orphanSessions = inv.orphans;

    if (managedSessions.length > 0) {
      console.log(`\x1b[32m●\x1b[0m Managed Sessions (${managedSessions.length})\n`);
      for (const s of managedSessions) {
        const label = managed.get(s.name) || s.name;
        const attachTag = s.attached ? "  \x1b[33m[attached]\x1b[0m" : "";
        console.log(`  \x1b[1m${s.name}\x1b[0m  (${s.windowCount} window${s.windowCount === 1 ? "" : "s"})${attachTag}  \x1b[36m[${label}]\x1b[0m`);
        for (const p of s.panes) {
          console.log(`    ${p.title || "pane"}: ${p.currentCommand}`);
        }
        console.log();
      }
    } else {
      console.log("\x1b[90m○\x1b[0m No managed sessions running.\n");
    }

    if (orphanSessions.length > 0) {
      console.log(`\x1b[33m○\x1b[0m Unmanaged Sessions (${orphanSessions.length})\n`);
      for (const s of orphanSessions) {
        const attachTag = s.attached ? "  \x1b[33m[attached]\x1b[0m" : "";
        console.log(`  \x1b[1m${s.name}\x1b[0m  (${s.windowCount} window${s.windowCount === 1 ? "" : "s"})${attachTag}`);
        for (const p of s.panes) {
          console.log(`    ${p.title || "pane"}: ${p.currentCommand}`);
        }
        console.log();
      }
    } else {
      console.log("\x1b[90m○\x1b[0m No unmanaged sessions.\n");
    }
  });
  return handled !== null;
}

// ── OCR commands ──────────────────────────────────────────────────────

async function scanCommand(sub?: string, ...rest: string[]): Promise<void> {
  if (!sub || sub === "snapshot" || sub === "ls" || sub === "--full" || sub === "-f" || sub === "--json") {
    const full = sub === "--full" || sub === "-f" || rest.includes("--full") || rest.includes("-f");
    const json = sub === "--json" || rest.includes("--json");
    await withDaemon(async ({ daemonCall }) => {
      const results = await daemonCall("ocr.snapshot", null, 5000) as any[];
      if (!results.length) {
        console.log("No scan results yet. The first scan runs ~60s after launch.");
        return;
      }
      if (json) {
        console.log(JSON.stringify(results, null, 2));
        return;
      }
      console.log(`\x1b[1mScan\x1b[0m  (${results.length} windows)\n`);
      for (const r of results) {
        const age = Math.round((Date.now() / 1000) - r.timestamp);
        const ageStr = age < 60 ? `${age}s ago` : age < 3600 ? `${Math.floor(age / 60)}m ago` : `${Math.floor(age / 3600)}h ago`;
        const src = r.source === "accessibility" ? "\x1b[33mAX\x1b[0m" : "\x1b[35mOCR\x1b[0m";
        const lines = (r.fullText || "").split("\n").filter(Boolean);
        console.log(`  \x1b[1m${r.app}\x1b[0m  wid:${r.wid}  ${src}  \x1b[90m${ageStr}\x1b[0m`);
        console.log(`    \x1b[36m"${r.title || "(untitled)"}"\x1b[0m`);
        if (lines.length) {
          if (full) {
            for (const line of lines) {
              console.log(`    \x1b[90m${line}\x1b[0m`);
            }
          } else {
            const maxPreview = 5;
            const preview = lines.slice(0, maxPreview).map((l: string) => l.length > 100 ? l.slice(0, 97) + "..." : l);
            for (const line of preview) {
              console.log(`    \x1b[90m${line}\x1b[0m`);
            }
            if (lines.length > maxPreview) {
              console.log(`    \x1b[90m… ${lines.length - maxPreview} more lines\x1b[0m`);
            }
          }
        } else {
          console.log(`    \x1b[90m(no text detected)\x1b[0m`);
        }
        console.log();
      }
    });
    return;
  }

  if (sub === "search") {
    const query = rest.join(" ");
    if (!query) {
      console.log("Usage: lats scan search <query>");
      return;
    }
    await withDaemon(async ({ daemonCall }) => {
      const results = await daemonCall("ocr.search", { query }, 5000) as any[];
      if (!results.length) {
        console.log(`No matches for "${query}".`);
        return;
      }
      console.log(`\x1b[1mSearch\x1b[0m  "${query}"  (${results.length} matches)\n`);
      for (const r of results) {
        const snippet = r.snippet || r.fullText?.slice(0, 120) || "";
        const src = r.source === "accessibility" ? "\x1b[33mAX\x1b[0m" : "\x1b[35mOCR\x1b[0m";
        console.log(`  ${src}  \x1b[1m${r.app}\x1b[0m  wid:${r.wid}`);
        console.log(`    \x1b[36m"${r.title || "(untitled)"}"\x1b[0m`);
        console.log(`    ${snippet}`);
        console.log();
      }
    });
    return;
  }

  if (sub === "recent" || sub === "log") {
    const full = rest.includes("--full") || rest.includes("-f");
    const numArg = rest.find(a => !a.startsWith("-"));
    const limit = parseInt(numArg || "", 10) || 20;
    await withDaemon(async ({ daemonCall }) => {
      const results = await daemonCall("ocr.history", { limit }, 5000) as any[];
      if (!results.length) {
        console.log("No history yet. The first scan runs ~60s after launch.");
        return;
      }
      console.log(`\x1b[1mRecent\x1b[0m  (${results.length} entries)\n`);
      for (const r of results) {
        const ts = new Date(r.timestamp * 1000).toLocaleTimeString();
        const src = r.source === "accessibility" ? "\x1b[33mAX\x1b[0m" : "\x1b[35mOCR\x1b[0m";
        const lines = (r.fullText || "").split("\n").filter(Boolean);
        console.log(`  \x1b[90m${ts}\x1b[0m  ${src}  \x1b[1m${r.app}\x1b[0m  wid:${r.wid}`);
        console.log(`    \x1b[36m"${r.title || "(untitled)"}"\x1b[0m`);
        if (full) {
          for (const line of lines) {
            console.log(`    \x1b[90m${line}\x1b[0m`);
          }
        } else {
          const maxPreview = 5;
          const preview = lines.slice(0, maxPreview).map((l: string) => l.length > 100 ? l.slice(0, 97) + "..." : l);
          for (const line of preview) {
            console.log(`    \x1b[90m${line}\x1b[0m`);
          }
          if (lines.length > maxPreview) {
            console.log(`    \x1b[90m… ${lines.length - maxPreview} more lines\x1b[0m`);
          }
        }
        console.log();
      }
    });
    return;
  }

  if (sub === "deep" || sub === "now" || sub === "scan") {
    await withDaemon(async ({ daemonCall }) => {
      console.log("Triggering deep scan (Vision OCR)...");
      await daemonCall("ocr.scan", null, 30000);
      console.log("Done.");
    });
    return;
  }

  if (sub === "history") {
    const wid = parseInt(rest[0], 10);
    if (isNaN(wid)) {
      console.log("Usage: lats scan history <wid>");
      return;
    }
    await withDaemon(async ({ daemonCall }) => {
      const results = await daemonCall("ocr.history", { wid }, 5000) as any[];
      if (!results.length) {
        console.log(`No history for wid:${wid}.`);
        return;
      }
      console.log(`\x1b[1mHistory\x1b[0m  wid:${wid}  (${results.length} entries)\n`);
      for (const r of results) {
        const ts = new Date(r.timestamp * 1000).toLocaleTimeString();
        const src = r.source === "accessibility" ? "\x1b[33mAX\x1b[0m" : "\x1b[35mOCR\x1b[0m";
        const lines = (r.fullText || "").split("\n").filter(Boolean);
        const preview = lines.slice(0, 2).map((l: string) => l.length > 80 ? l.slice(0, 77) + "..." : l);
        console.log(`  \x1b[90m${ts}\x1b[0m  ${src}  \x1b[1m${r.app}\x1b[0m — "${r.title}"`);
        for (const line of preview) {
          console.log(`    \x1b[90m${line}\x1b[0m`);
        }
        console.log();
      }
    });
    return;
  }

  // Unknown subcommand
  console.log(`lats scan — Screen text recognition

Usage:
  lats scan               Show text from all visible windows
  lats scan --full        Full text dump
  lats scan --json        JSON output
  lats scan search <q>    Full-text search across scanned windows
  lats scan recent [n]    Show recent scans chronologically (default 20)
  lats scan deep          Trigger a deep Vision OCR scan
  lats scan history <wid> Show scan timeline for a window
`);
}

function buildHomeContext() {
  const dir = process.cwd();
  const sessionName = toSessionName(dir);
  const config = readConfig(dir);
  const panes = resolvePanes(dir);
  const tmuxReady = hasTmux();
  const sessionRunning = tmuxReady && sessionExists(sessionName);
  const appRunning = runQuiet("pgrep -x Lattices >/dev/null 2>&1 && echo yes") === "yes";
  return {
    dir,
    sessionName,
    configLabel: config ? ".lattices.json" : "none yet",
    paneNames: panes.map((p) => p.name || "pane").join(", "),
    sessionsStatus: tmuxReady ? (sessionRunning ? "running" : "ready") : "missing",
    appStatus: appRunning ? "running" : "not running",
    tmuxReady,
  };
}

function initConfig(): void {
  const dir = process.cwd();
  const configPath = resolve(dir, ".lattices.json");

  if (existsSync(configPath)) {
    console.log(".lattices.json already exists.");
    return;
  }

  const panes = defaultPanes(dir);
  const config = {
    ensure: true,
    panes,
  };

  writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
  console.log("Created .lattices.json");
  console.log(JSON.stringify(config, null, 2));
}

function listSessions(): void {
  const out = runQuiet(
    "tmux list-sessions -F '#{session_name}  (#{session_windows} windows, created #{session_created_string})'"
  );
  if (!out) {
    console.log("No active sessions.");
    return;
  }

  // Annotate sessions that belong to tab groups
  const ws = readWorkspaceConfig();
  const sessionGroupMap = new Map<string, { group: string; tab: string }>();
  if (ws?.groups) {
    for (const g of ws.groups) {
      for (const tab of g.tabs || []) {
        if (!tab.path) continue;
        const tabSession = toSessionName(resolve(tab.path));
        sessionGroupMap.set(tabSession, {
          group: g.label || g.id,
          tab: tabLabel(tab),
        });
      }
    }
  }

  const lines = out.split("\n").map((line: string) => {
    const sessionName = line.split("  ")[0];
    const info = sessionGroupMap.get(sessionName);
    return info
      ? `${line}  \x1b[36m[${info.group}: ${info.tab}]\x1b[0m`
      : line;
  });

  console.log("Sessions:\n");
  console.log(lines.join("\n"));
}

function killSession(name?: string): void {
  if (!name) name = toSessionName(process.cwd());
  if (!sessionExists(name)) {
    console.log(`No session "${name}".`);
    return;
  }
  run(`tmux kill-session -t "${name}"`);
  console.log(`Killed "${name}".`);
}

// ── Window tiling ────────────────────────────────────────────────────

interface ScreenBounds {
  x: number;
  y: number;
  w: number;
  h: number;
}

function getScreenBounds(): ScreenBounds {
  // Get the visible area (excludes menu bar and dock) in AppleScript coordinates (top-left origin)
  const script = `
    tell application "Finder"
      set db to bounds of window of desktop
    end tell
    -- db = {left, top, right, bottom} of usable desktop
    return (item 1 of db) & "," & (item 2 of db) & "," & (item 3 of db) & "," & (item 4 of db)`;
  const out = runQuiet(`osascript -e '${esc(script)}'`);
  if (!out) return { x: 0, y: 25, w: 1920, h: 1055 };
  const [x, y, right, bottom] = out.split(",").map(s => parseInt(s.trim()));
  return { x, y, w: right - x, h: bottom - y };
}

// Presets return AppleScript bounds: [left, top, right, bottom] within the visible area
const tilePresets: Record<string, (s: ScreenBounds) => number[]> = {
  "left":         (s) => [s.x, s.y, s.x + s.w / 2, s.y + s.h],
  "left-half":    (s) => [s.x, s.y, s.x + s.w / 2, s.y + s.h],
  "right":        (s) => [s.x + s.w / 2, s.y, s.x + s.w, s.y + s.h],
  "right-half":   (s) => [s.x + s.w / 2, s.y, s.x + s.w, s.y + s.h],
  "top":          (s) => [s.x, s.y, s.x + s.w, s.y + s.h / 2],
  "top-half":     (s) => [s.x, s.y, s.x + s.w, s.y + s.h / 2],
  "bottom":       (s) => [s.x, s.y + s.h / 2, s.x + s.w, s.y + s.h],
  "bottom-half":  (s) => [s.x, s.y + s.h / 2, s.x + s.w, s.y + s.h],
  "top-left":     (s) => [s.x, s.y, s.x + s.w / 2, s.y + s.h / 2],
  "top-right":    (s) => [s.x + s.w / 2, s.y, s.x + s.w, s.y + s.h / 2],
  "bottom-left":  (s) => [s.x, s.y + s.h / 2, s.x + s.w / 2, s.y + s.h],
  "bottom-right": (s) => [s.x + s.w / 2, s.y + s.h / 2, s.x + s.w, s.y + s.h],
  "maximize":     (s) => [s.x, s.y, s.x + s.w, s.y + s.h],
  "max":          (s) => [s.x, s.y, s.x + s.w, s.y + s.h],
  "center":       (s) => {
    const mw = Math.round(s.w * 0.8);
    const mh = Math.round(s.h * 0.8);
    const mx = s.x + Math.round((s.w - mw) / 2);
    const my = s.y + Math.round((s.h - mh) / 2);
    return [mx, my, mx + mw, my + mh];
  },
  "left-third":   (s) => [s.x, s.y, s.x + Math.round(s.w * 0.333), s.y + s.h],
  "center-third": (s) => [s.x + Math.round(s.w * 0.333), s.y, s.x + Math.round(s.w * 0.667), s.y + s.h],
  "right-third":  (s) => [s.x + Math.round(s.w * 0.667), s.y, s.x + s.w, s.y + s.h],
};

type SpaceOptimizeScope = "visible" | "active-app" | "app";

interface SpaceOptimizeRequest {
  scope: SpaceOptimizeScope;
  app?: string;
  region?: string;
}

function isPlacementToken(value?: string): boolean {
  if (!value) return false;
  const normalized = value.toLowerCase();
  return normalized in tilePresets || /^(?:grid:)?\d+x\d+:\d+,\d+(?:-\d+,\d+)?$/i.test(normalized);
}

function parseSpaceOptimizeArgs(rawArgs: string[], defaultScope: SpaceOptimizeScope): SpaceOptimizeRequest {
  const parts = rawArgs.filter(Boolean);
  if (!parts.length) return { scope: defaultScope };

  const last = parts[parts.length - 1];
  const region = isPlacementToken(last) ? last : undefined;
  const appParts = region ? parts.slice(0, -1) : parts;
  const app = appParts.length ? appParts.join(" ") : undefined;

  if (app) return { scope: "app", app, region };
  return { scope: defaultScope, region };
}

function formatOptimizeTarget(request: SpaceOptimizeRequest): string {
  if (request.app) return `"${request.app}"`;
  return request.scope === "active-app" ? "the frontmost app" : "all visible windows";
}

async function optimizeWindowsCommand(
  request: SpaceOptimizeRequest,
  successVerb: string
): Promise<void> {
  await withDaemon(async ({ daemonCall }) => {
    const params: Record<string, unknown> = {
      scope: request.scope,
      strategy: "balanced",
    };
    if (request.app) params.app = request.app;
    if (request.region) params.region = request.region;

    const result = await daemonCall("spaces.optimize", params) as any;
    const count = result?.windowCount ?? 0;
    const target = formatOptimizeTarget(request);
    const regionSuffix = request.region ? ` in the ${request.region} region` : "";

    if (count === 0) {
      console.log(`No eligible windows found for ${target}${regionSuffix}.`);
      return;
    }

    console.log(
      `${successVerb} ${count} window${count === 1 ? "" : "s"} for ${target}${regionSuffix}.`
    );
  });
}

function gridTileBounds(position: string, screen: ScreenBounds): number[] | null {
  const match = position.toLowerCase().match(/^(grid:)?(\d+)x(\d+):(\d+),(\d+)(?:-(\d+),(\d+))?$/);
  if (!match) return null;

  const oneBased = !match[1];
  const columns = Number(match[2]);
  const rows = Number(match[3]);
  let c0 = Number(match[4]);
  let r0 = Number(match[5]);
  let c1 = match[6] === undefined ? c0 : Number(match[6]);
  let r1 = match[7] === undefined ? r0 : Number(match[7]);
  if (oneBased) {
    c0 -= 1;
    r0 -= 1;
    c1 -= 1;
    r1 -= 1;
  }
  const leftCell = Math.min(c0, c1);
  const rightCell = Math.max(c0, c1);
  const topCell = Math.min(r0, r1);
  const bottomCell = Math.max(r0, r1);

  if (
    columns <= 0 || rows <= 0 ||
    leftCell < 0 || topCell < 0 ||
    rightCell >= columns || bottomCell >= rows
  ) {
    return null;
  }

  const cellW = screen.w / columns;
  const cellH = screen.h / rows;
  return [
    screen.x + leftCell * cellW,
    screen.y + topCell * cellH,
    screen.x + (rightCell + 1) * cellW,
    screen.y + (bottomCell + 1) * cellH,
  ];
}

/**
 * Legacy `lats tile <position>`: prefer the canonical daemon placement
 * (windows.place, frontmost target). Only when the daemon is down fall back to
 * the AppleScript path — and say so, since that path is frontmost-app,
 * primary-display only.
 */
async function tileFrontmostCommand(position: string): Promise<void> {
  const { normalizePlacement, describeMoveReceipt } = await import("./cli/window.ts");
  const placement = normalizePlacement(position);
  if (!placement) {
    tileWindow(position); // prints the unknown-position help
    return;
  }

  const client = await loadDaemonClient();
  if (await client.isDaemonRunning()) {
    try {
      const receipt = await client.daemonCall("windows.place", { placement });
      console.log(describeMoveReceipt(receipt));
    } catch (e: unknown) {
      console.error(`Daemon placement failed: ${(e as Error).message}`);
      process.exit(1);
    }
    return;
  }

  console.log("Daemon not running — AppleScript fallback (frontmost app, primary display).");
  tileWindow(position);
}

function tileWindow(position: string): void {
  const normalized = position.toLowerCase();
  const screen = getScreenBounds();
  const bounds = tilePresets[normalized]?.(screen) ?? gridTileBounds(normalized, screen);
  if (!bounds) {
    console.log(`Unknown position: ${position}`);
    console.log(`Available: ${Object.keys(tilePresets).filter(k => !k.includes("-half") && k !== "max").join(", ")}, grid:CxR:c,r (0-based), CxR:c,r (1-based)`);
    return;
  }
  const [x1, y1, x2, y2] = bounds.map(Math.round);
  const script = `
    tell application "System Events"
      set frontApp to name of first application process whose frontmost is true
    end tell
    tell application frontApp
      set bounds of front window to {${x1}, ${y1}, ${x2}, ${y2}}
    end tell`;
  runQuiet(`osascript -e '${esc(script)}'`);
  console.log(`Tiled → ${normalized}`);
}

function createOrAttach(): void {
  const dir = process.cwd();
  const name = toSessionName(dir);

  if (sessionExists(name)) {
    console.log(`Reattaching to "${name}"...`);
    const config = readConfig(dir);
    if (config?.ensure) {
      restoreCommands(name, dir, "ensure");
    } else if (config?.prefill) {
      restoreCommands(name, dir, "prefill");
    }
    attach(name);
    return;
  }

  console.log(`Creating "${name}"...`);
  createSession(dir);
  attach(name);
}

function attach(name: string): void {
  if (isInsideTmux()) {
    execFileSync("tmux", ["switch-client", "-t", name], { stdio: "inherit" });
  } else {
    execFileSync("tmux", ["attach", "-t", name], { stdio: "inherit" });
  }
}

// ── Status / Inventory ───────────────────────────────────────────────

function statusInventory(): void {
  // Query all tmux sessions
  const sessionsRaw = runQuiet(
    'tmux list-sessions -F "#{session_name}\t#{session_windows}\t#{session_attached}"'
  );
  if (!sessionsRaw) {
    console.log("No active sessions.");
    return;
  }

  // Query all panes
  const panesRaw = runQuiet(
    'tmux list-panes -a -F "#{session_name}\t#{pane_title}\t#{pane_current_command}"'
  );

  // Parse panes grouped by session
  const panesBySession = new Map<string, { title: string; cmd: string }[]>();
  if (panesRaw) {
    for (const line of panesRaw.split("\n").filter(Boolean)) {
      const [sess, title, cmd] = line.split("\t");
      if (!panesBySession.has(sess)) panesBySession.set(sess, []);
      panesBySession.get(sess)!.push({ title, cmd });
    }
  }

  // Build managed session name set
  const managed = new Map<string, string>(); // name -> label

  // From workspace groups
  const ws = readWorkspaceConfig();
  if (ws?.groups) {
    for (const g of ws.groups) {
      for (const tab of g.tabs || []) {
        if (!tab.path) continue;
        const name = toSessionName(resolve(tab.path));
        const label = `${g.label || g.id}: ${tabLabel(tab)}`;
        managed.set(name, label);
      }
    }
  }

  // From scanning .lattices.json files
  const scanRoot =
    process.env.LATTICE_SCAN_ROOT ||
    resolve(homedir(), "dev");
  const findResult = runQuiet(
    `find "${scanRoot}" -name .lattices.json -maxdepth 3 -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null`
  );
  if (findResult) {
    for (const configPath of findResult.split("\n").filter(Boolean)) {
      const dir = resolve(configPath, "..");
      const name = toSessionName(dir);
      if (!managed.has(name)) {
        managed.set(name, basename(dir));
      }
    }
  }

  // Parse sessions and classify
  const sessions = sessionsRaw.split("\n").filter(Boolean).map((line: string) => {
    const [name, windows, attached] = line.split("\t");
    return { name, windows: parseInt(windows) || 1, attached: attached !== "0" };
  });

  const managedSessions = sessions.filter((s) => managed.has(s.name));
  const orphanSessions = sessions.filter((s) => !managed.has(s.name));

  // Print managed
  if (managedSessions.length > 0) {
    console.log(`\x1b[32m●\x1b[0m Managed Sessions (${managedSessions.length})\n`);
    for (const s of managedSessions) {
      const label = managed.get(s.name);
      const attachTag = s.attached ? "  \x1b[33m[attached]\x1b[0m" : "";
      console.log(`  \x1b[1m${s.name}\x1b[0m  (${s.windows} window${s.windows === 1 ? "" : "s"})${attachTag}  \x1b[36m[${label}]\x1b[0m`);
      const panes = panesBySession.get(s.name) || [];
      for (const p of panes) {
        const name = p.title || "pane";
        console.log(`    ${name}: ${p.cmd}`);
      }
      console.log();
    }
  } else {
    console.log("\x1b[90m○\x1b[0m No managed sessions running.\n");
  }

  // Print orphans
  if (orphanSessions.length > 0) {
    console.log(`\x1b[33m○\x1b[0m Unmanaged Sessions (${orphanSessions.length})\n`);
    for (const s of orphanSessions) {
      const attachTag = s.attached ? "  \x1b[33m[attached]\x1b[0m" : "";
      console.log(`  \x1b[1m${s.name}\x1b[0m  (${s.windows} window${s.windows === 1 ? "" : "s"})${attachTag}`);
      const panes = panesBySession.get(s.name) || [];
      for (const p of panes) {
        const name = p.title || "pane";
        console.log(`    ${name}: ${p.cmd}`);
      }
      console.log();
    }
  } else {
    console.log("\x1b[90m○\x1b[0m No unmanaged sessions.\n");
  }
}

// ── Main ─────────────────────────────────────────────────────────────

requireTmux(command);

await resolveDisplayNames(args);

switch (command) {
  case undefined:
    printHome(buildHomeContext());
    break;
  case "start":
  case "tmux":
    createOrAttach();
    break;
  case "init":
    initConfig();
    break;
  case "ls":
  case "list":
    // Try daemon first, fall back to direct tmux
    if (!(await daemonLsCommand())) {
      listSessions();
    }
    break;
  case "kill":
  case "rm":
    killSession(args[1]);
    break;
  case "sync":
  case "reconcile":
    syncSession();
    break;
  case "restart":
  case "respawn":
    restartPane(args[1]);
    break;
  case "group":
    groupCommand(args[1]);
    break;
  case "groups":
    listGroups();
    break;
  case "tab":
    tabCommand(args[1], args[2]);
    break;
  case "status":
  case "inventory":
    // Try daemon first, fall back to direct tmux
    if (!(await daemonStatusInventory())) {
      statusInventory();
    }
    break;
  case "distribute":
    await distributeCommand(args.slice(1));
    break;
  case "tile":
  case "t":
    if (args[1] === "family" || args[1] === "app") {
      await tileFamilyCommand(args.slice(2));
    } else if (args[1] === "all") {
      await distributeCommand(args.slice(2));
    } else if (args[1]) {
      await tileFrontmostCommand(args[1]);
    } else {
      console.log("Usage:");
      console.log("  lats tile <position>");
      console.log("  lats tile family [app-name] [region]");
      console.log("  lats tile all [app-name] [region]\n");
      console.log("Examples:");
      console.log("  lats tile left");
      console.log("  lats tile family");
      console.log("  lats tile family right");
      console.log("  lats tile family iTerm2");
      console.log("  lats tile all Google Chrome left\n");
      console.log("Positions: left, right, top, bottom, top-left, top-right,");
      console.log("           bottom-left, bottom-right, maximize, center,");
      console.log("           left-third, center-third, right-third");
    }
    break;
  case "windows":
    await windowsCommand(args[1] === "--json");
    break;
  case "map":
    if (args.includes("--help") || args.includes("-h")) {
      console.log(mapUsage());
    } else {
      await withDaemon(async ({ daemonCall }) => mapCommand(args.slice(1), daemonCall));
    }
    break;
  case "window":
    if (args[1] === "assign") {
      await windowAssignCommand(args[2], args[3]);
    } else if (args[1] === "move" || args[1] === "place") {
      const method = args[1];
      const { parseWindowMoveArgs, parseWindowPlaceArgs, runWindowMovement, windowMoveUsage } =
        await import("./cli/window.ts");
      const rest = args.slice(2);
      if (rest.includes("--help") || rest.includes("-h")) {
        console.log(windowMoveUsage());
        break;
      }
      // Parse before touching the daemon: malformed input (a bad wid above
      // all) must fail here and never fall back to another window.
      let parsed;
      try {
        parsed = method === "move" ? parseWindowMoveArgs(rest) : parseWindowPlaceArgs(rest);
      } catch (e: unknown) {
        console.error((e as Error).message);
        process.exit(1);
      }
      await withDaemon(async ({ daemonCall }) => runWindowMovement(method, parsed, daemonCall));
    } else {
      const { windowMoveUsage } = await import("./cli/window.ts");
      console.log("Usage:");
      console.log("  lats window move <wid> --display <n> [--placement <slot>] [--dry-run] [--json]");
      console.log("  lats window place <wid> <slot> [--display <n>] [--dry-run] [--json]");
      console.log("  lats window assign <wid> <layer>      Same as: lats layer add wid:N --to <layer>");
      console.log("");
      console.log(windowMoveUsage());
    }
    break;
  case "search":
  case "s":
    await searchCommand(args[1], new Set(args.slice(2)), args.slice(2));
    break;
  case "focus":
    await focusCommand(args[1]);
    break;
  case "place":
    await placeCommand(args[1], args[2]);
    break;
  case "sessions":
    await sessionsCommand(args[1] === "--json");
    break;
  case "terminals":
    await terminalsCommand(args.slice(1));
    break;
  case "capture":
    await captureCommand(args[1], ...args.slice(2));
    break;
  case "runs":
    await runsCommand(args.slice(1));
    break;
  case "run":
    await runsCommand(args.slice(1));
    break;
  case "computer":
    await computerCommand(args[1], ...args.slice(2));
    break;
  case "cua":
    await computerCommand(args[1], ...args.slice(2));
    break;
  case "voice":
    await voiceCommand(args[1], ...args.slice(2));
    break;
  case "actor":
  case "actors":
    await actorCommand(args[1], ...args.slice(2));
    break;
  case "hud":
  case "huds":
    await hudCommand(args[1], ...args.slice(2));
    break;
  case "assistant":
    await assistantCommand(args[1], ...args.slice(2));
    break;
  case "call":
    await callCommand(args[1], ...args.slice(2));
    break;
  case "hosts":
    await hostsCommand(args.slice(1));
    break;
  case "pair":
    await hostsCommand(args);
    break;
  case "layer":
  case "layers":
    await layerCommand(args[1], ...args.slice(2));
    break;
  case "machines": {
    const { machinesCommand } = await import("./cli/machines.ts");
    await machinesCommand(args.includes("--json"));
    break;
  }
  case "bring":
  case "main":
  case "elsewhere":
  case "here":
  case "home":
    await withDaemon(async ({ daemonCall }) => {
      if (command !== "home" && !args[1]) throw new Error(`Usage: lats ${command} <display>`);
      const params = command === "home" ? {} : command === "bring" && args[1] === "--undo" ? { undo: true } : {
        display: args[1], ...(command === "main" ? { keep: args.includes("--keep") } : {}),
        ...(command === "elsewhere" && args[2] ? { name: args[2] } : {}),
      };
      console.log(JSON.stringify(await daemonCall(command, params), null, 2));
    });
    break;
  case "display":
  case "displays":
    await displayCommand(args[1], ...args.slice(2));
    break;
  case "state":
  case "states":
    await stateCommand(args[1], ...args.slice(2));
    break;
  case "diag":
  case "diagnostics":
  case "log":
  case "logs":
  case "activity":
    await diagCommand(args[1]);
    break;
  case "scan":
  case "ocr":
    await scanCommand(args[1], ...args.slice(2));
    break;
  case "mouse":
    await mouseCommand(args[1]);
    break;
  case "visit":
    await visitCommand(args[1], args.slice(2));
    break;
  case "long":
    await withDaemon(async ({ daemonCall }) => {
      const result = await daemonCall("long.show", { on: args[1] !== "hide" }) as any;
      console.log(result.shown ? "Long's on the desktop" : "Long's hidden");
    });
    break;
  case "daemon":
    if (args[1] === "status") {
      await daemonStatusCommand();
    } else {
      console.log("Usage: lats daemon status");
    }
    break;
  case "dev":
    await devCommand(args[1], ...args.slice(2));
    break;
  case "app": {
    const { execFileSync } = await import("node:child_process");
    const dir = process.cwd();
    const first = args[1];
    const appSubcommand = first && !first.startsWith("-") ? first : "launch";
    const appFlags = first && !first.startsWith("-") ? args.slice(2) : args.slice(1);
    const devAppCommands = new Set([
      "launch", "start", "build", "restart", "quit", "stop",
      "install", "uninstall", "login", "startup", "status",
    ]);

    if (detectProjectType(dir) === "lattices-app" && devAppCommands.has(appSubcommand)) {
      console.log("Using local dev app bundle so macOS permissions stay attached across rebuilds.");
      await forwardToLatticesDevHelper(dir, appSubcommand, appFlags);
      break;
    }

    // Forward release/package app commands to lattices-app script.
    const appScript = resolve(import.meta.dir, "lattices-app.ts");
    try {
      execFileSync("bun", [appScript, ...args.slice(1)], { stdio: "inherit" });
    } catch { /* exit code forwarded */ }
    break;
  }
  case "update":
  case "upgrade": {
    const { execFileSync } = await import("node:child_process");
    const appScript = resolve(import.meta.dir, "lattices-app.ts");
    try {
      execFileSync("bun", [appScript, "upgrade", ...args.slice(1)], { stdio: "inherit" });
    } catch { /* exit code forwarded */ }
    break;
  }
  case "mcp": {
    // Serve the MCP over stdio. Loaded on demand so the toolsets -- and the
    // resources they own -- are never touched by an unrelated CLI invocation.
    const { mcpCommand } = await import("./mcp/server.ts");
    await mcpCommand(args.slice(1));
    break;
  }
  case "action": {
    const { execFileSync } = await import("node:child_process");
    const actionScript = resolve(import.meta.dir, "lattices-action.ts");
    try {
      execFileSync("bun", [actionScript, ...args.slice(1)], { stdio: "inherit" });
    } catch (error) {
      process.exitCode = typeof (error as { status?: unknown }).status === "number"
        ? (error as { status: number }).status : 1;
    }
    break;
  }
  case "-h":
  case "--help":
  case "help":
    printUsage();
    break;
  default:
    console.log(`Unknown command: ${command}`);
    console.log("Run `lats help` for the full command reference.");
}
