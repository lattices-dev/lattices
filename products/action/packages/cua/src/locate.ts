/**
 * The one answer to "which Action.app?", shared by `action status`/`launch`,
 * action-cua and the permission ask: ACTION_APP (or an explicit path), the
 * standard install locations, then the Action that is running now. Spotlight
 * is not consulted: on a development Mac it returns every dev, QA and staging
 * build, and the first hit is an arbitrary one.
 */
import { execFileSync } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const EXECUTABLE = "Contents/MacOS/Action";

export function isActionApp(path: string): boolean {
  try {
    accessSync(join(path, EXECUTABLE), constants.X_OK);
    return statSync(path).isDirectory() && statSync(join(path, EXECUTABLE)).isFile();
  } catch { return false; }
}

/** Bundles of running processes named Action, from their executable paths. */
export function runningActionApps(): string[] {
  let pids: string[];
  try { pids = execFileSync("pgrep", ["-x", "Action"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim().split("\n").filter(Boolean); } catch { return []; }
  const apps: string[] = [];
  for (const pid of pids) {
    try {
      const command = execFileSync("ps", ["-o", "comm=", "-p", pid], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
      const suffix = `/${EXECUTABLE}`;
      if (command.endsWith(suffix)) apps.push(command.slice(0, -suffix.length));
    } catch { /* exited */ }
  }
  return apps;
}

export function actionAppCandidates(explicit?: string, options: { running?: boolean } = {}): string[] {
  const configured = [explicit, process.env.ACTION_APP].filter((value): value is string => typeof value === "string" && value.trim().length > 0).map((value) => value.trim());
  const standard = ["/Applications/Action.app", join(homedir(), "Applications/Action.app")];
  return [...configured, ...standard, ...(options.running === false ? [] : runningActionApps())];
}

/** The running Action is consulted only when no configured or standard bundle exists. */
export function findActionApp(explicit?: string, options: { running?: boolean } = {}): string | undefined {
  return actionAppCandidates(explicit, { running: false }).find(isActionApp)
    ?? (options.running === false ? undefined : runningActionApps().find(isActionApp));
}
