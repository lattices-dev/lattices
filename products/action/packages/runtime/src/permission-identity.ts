import { execFile } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { promisify } from "node:util";

import type { EngineDiagnostics, PermissionState } from "@action/protocol";

import type { AgentPermissionSnapshot } from "./drive-client.js";

const execFileAsync = promisify(execFile);

export const ACTION_APP_BUNDLE_ID = "dev.lattices.Action";

/**
 * macOS keeps one Accessibility and one Screen Recording row per bundle id, bound
 * to the code requirement of the copy that was granted. Two copies of Action with
 * the same id but different signers (Developer ID vs Apple Development) cannot both
 * hold it: granting one silently revokes the other while System Settings still
 * shows Action switched on. Everything here exists to name that case instead of
 * reporting a bare "denied".
 */
export type ActionSigner = "developer-id" | "apple-development" | "ad-hoc" | "unsigned" | "unknown";

export interface ActionBundleSigning {
  path: string;
  signer: ActionSigner;
  authority?: string;
  teamId?: string;
  /** The designated requirement TCC records when this copy is granted. */
  requirement?: string;
}

export type PermissionVerdict =
  /** The agent can use both. */
  | "granted"
  /** Nothing is wrong with identity; the operator has to switch Action on. */
  | "needs-grant"
  /** Copies signed differently share one bundle id, so a grant can belong to the wrong one. */
  | "identity-split"
  /** A fresh process sees the grant but the running agent does not; it has to restart. */
  | "stale-agent";

export interface PermissionReport {
  verdict: PermissionVerdict;
  /** What the agent doing the work sees; the host probe only when no agent answered. */
  accessibility: PermissionState;
  screenRecording: PermissionState;
  source: "agent" | "host";
  /** The copy macOS has to allow. */
  grantTarget?: string;
  fix?: string;
  agent?: AgentPermissionSnapshot & { app?: ActionBundleSigning };
  agentError?: string;
  host?: EngineDiagnostics & { app?: ActionBundleSigning };
  copies: ActionBundleSigning[];
  warnings: string[];
}

export function classifySigner(authority: string | undefined, signature: string | undefined): ActionSigner {
  if (signature === "adhoc") return "ad-hoc";
  if (!authority) return "unknown";
  if (authority.startsWith("Developer ID Application:")) return "developer-id";
  if (authority.startsWith("Apple Development:")) return "apple-development";
  return "unknown";
}

/** Parses `codesign -dv --verbose=2` (stderr) and `codesign -d -r-` (stdout). */
export function parseCodesign(path: string, details: string, requirementOutput: string): ActionBundleSigning {
  const field = (name: string) => details.match(new RegExp(`^${name}=(.+)$`, "m"))?.[1]?.trim();
  const authority = field("Authority");
  const teamId = field("TeamIdentifier");
  const requirement = requirementOutput.match(/designated => (.+)$/m)?.[1]?.trim();
  return {
    path,
    signer: classifySigner(authority, field("Signature")),
    authority,
    teamId: teamId && teamId !== "not set" ? teamId : undefined,
    requirement,
  };
}

export async function inspectBundleSigning(path: string): Promise<ActionBundleSigning> {
  try {
    const details = await execFileAsync("/usr/bin/codesign", ["-dv", "--verbose=2", path], { timeout: 5000 });
    const requirement = await execFileAsync("/usr/bin/codesign", ["-d", "-r-", path], { timeout: 5000 })
      .then((result) => result.stdout + result.stderr)
      .catch(() => "");
    return parseCodesign(path, details.stderr + details.stdout, requirement);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { path, signer: /not signed/i.test(message) ? "unsigned" : "unknown" };
  }
}

/** The app whose TCC rows apply to a process: a helper inside Contents/Helpers runs on its host app's grant. */
export function owningActionApp(bundlePath: string): string {
  const marker = "/Contents/Helpers/";
  const index = bundlePath.indexOf(marker);
  return index >= 0 ? bundlePath.slice(0, index) : bundlePath;
}

/** The bundle `run-app-host.sh` launches, mirroring its own APP_DIR resolution. */
export function hostAppPath(nativeHostPath: string): string {
  const actionRoot = resolve(dirname(nativeHostPath), "../../..");
  return resolve(process.env.ACTION_DIST_DIR ?? resolve(actionRoot, "native/dist"), "Action.app");
}

function canonicalPath(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

/** Every Action.app on this Mac: Spotlight's answer plus the paths Action itself uses. */
export async function findActionCopies(knownPaths: string[] = []): Promise<string[]> {
  const candidates = new Set<string>();
  for (const path of [
    "/Applications/Action.app",
    resolve(homedir(), "Applications/Action.app"),
    ...knownPaths,
  ]) {
    if (existsSync(path)) candidates.add(canonicalPath(path));
  }

  try {
    const { stdout } = await execFileAsync(
      "/usr/bin/mdfind",
      [`kMDItemCFBundleIdentifier == '${ACTION_APP_BUNDLE_ID}'`],
      { timeout: 3000 },
    );
    for (const line of stdout.split("\n")) {
      const path = line.trim();
      if (path && !path.includes("/.Trash/") && !path.includes(".app/Contents/")) {
        candidates.add(canonicalPath(path));
      }
    }
  } catch {
    // Spotlight off or slow: the known paths still cover the copies Action launches.
  }

  return [...candidates].sort();
}

const signerKey = (copy: ActionBundleSigning) => copy.requirement ?? `${copy.signer}:${copy.authority ?? ""}`;

const signerLabel: Record<ActionSigner, string> = {
  "developer-id": "Developer ID",
  "apple-development": "Apple Development",
  "ad-hoc": "ad-hoc",
  unsigned: "unsigned",
  unknown: "unknown signer",
};

export interface PermissionDiagnosisInput {
  agent?: AgentPermissionSnapshot & { app?: ActionBundleSigning };
  agentError?: string;
  host?: EngineDiagnostics & { app?: ActionBundleSigning };
  copies: ActionBundleSigning[];
}

export function diagnosePermissions(input: PermissionDiagnosisInput): PermissionReport {
  const { agent, host, copies } = input;
  const source = agent ? "agent" : "host";
  const accessibility = agent?.accessibility ?? host?.accessibility ?? "unknown";
  const screenRecording = agent?.screenRecording ?? host?.screenRecording ?? "unknown";
  const grantTarget = agent?.app?.path ?? host?.app?.path;
  const target = copies.find((copy) => copy.path === grantTarget) ?? agent?.app ?? host?.app;
  const warnings: string[] = [];

  // Copies whose signature cannot satisfy the requirement of the copy that does the work.
  const conflicting = target
    ? copies.filter((copy) => copy.path !== target.path && signerKey(copy) !== signerKey(target))
    : [];
  const conflictList = conflicting.map((copy) => `${copy.path} (${signerLabel[copy.signer]})`).join(", ");
  if (conflicting.length > 0) {
    warnings.push(
      `Other Action copies are signed differently from ${target?.path}: ${conflictList}. Granting one of them revokes this one.`,
    );
  }
  if (!target && new Set(copies.map(signerKey)).size > 1) {
    warnings.push(
      `Action copies on this Mac are signed differently (${copies.map((copy) => `${copy.path} (${signerLabel[copy.signer]})`).join(", ")}). Only one signature can hold the grant at a time.`,
    );
  }
  if (target && target.signer !== "developer-id") {
    warnings.push(
      `${target.path} is signed ${signerLabel[target.signer]}, not Developer ID; its grant will not carry over to the installed release.`,
    );
  }
  if (!agent && input.agentError) {
    warnings.push(`The agent did not answer (${input.agentError}); permissions come from a fresh host probe.`);
  }

  const base = { accessibility, screenRecording, source, grantTarget, agent, agentError: input.agentError, host, copies, warnings } as const;

  if (accessibility === "granted" && screenRecording === "granted") {
    return { ...base, verdict: "granted" };
  }

  const missing = [
    accessibility !== "granted" ? "Accessibility" : undefined,
    screenRecording !== "granted" ? "Screen Recording" : undefined,
  ].filter(Boolean).join(" and ");

  // A fresh launch of the same signature sees the grant; the long-lived agent read
  // it before the grant landed (Screen Recording is cached per process).
  const sameIdentity = agent?.app && host?.app && signerKey(agent.app) === signerKey(host.app);
  if (
    agent &&
    sameIdentity &&
    (agent.accessibility !== "granted" ? host?.accessibility === "granted" : true) &&
    (agent.screenRecording !== "granted" ? host?.screenRecording === "granted" : true)
  ) {
    return {
      ...base,
      verdict: "stale-agent",
      fix: `macOS already allows ${missing} for this signature, but the running agent read it before the grant. Quit and reopen Action (or restart its agent from Settings › Permissions).`,
    };
  }

  if (conflicting.length > 0 || (agent?.app && host?.app && !sameIdentity)) {
    const others = conflicting.length > 0 ? conflictList : `${host?.app?.path} (${signerLabel[host?.app?.signer ?? "unknown"]})`;
    return {
      ...base,
      verdict: "identity-split",
      fix: `Several copies of Action share the bundle id ${ACTION_APP_BUNDLE_ID} but are signed differently: ${others}. Delete or rebuild them with Developer ID, then in Action › Settings › Permissions drag ${grantTarget} into ${missing} (or press Reset).`,
    };
  }

  return {
    ...base,
    verdict: "needs-grant",
    fix: `Open Action › Settings › Permissions and allow ${grantTarget ?? "Action"} in ${missing}.`,
  };
}

export interface CollectPermissionReportInput {
  /** Asks the running agent; resolves undefined fields when it cannot answer. */
  agentPermissions?: () => Promise<AgentPermissionSnapshot>;
  /** A fresh launch of the host app (`run-app-host.sh status`). */
  hostDiagnostics?: () => Promise<EngineDiagnostics>;
  nativeHostPath: string;
  timeoutMs?: number;
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> {
  return new Promise<T>((resolvePromise, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolvePromise(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

export async function collectPermissionReport(input: CollectPermissionReportInput): Promise<PermissionReport> {
  const timeoutMs = input.timeoutMs ?? 4000;
  const hostApp = hostAppPath(input.nativeHostPath);

  const [agentResult, hostResult] = await Promise.allSettled([
    input.agentPermissions
      ? withTimeout(input.agentPermissions(), timeoutMs, "Agent permission snapshot")
      : Promise.reject(new Error("no agent client")),
    input.hostDiagnostics ? input.hostDiagnostics() : Promise.reject(new Error("no host probe")),
  ]);

  const agentSnapshot = agentResult.status === "fulfilled" ? agentResult.value : undefined;
  const agentError = agentResult.status === "rejected"
    ? (agentResult.reason instanceof Error ? agentResult.reason.message : String(agentResult.reason))
    : undefined;
  const hostDiagnostics = hostResult.status === "fulfilled" ? hostResult.value : undefined;

  const agentApp = agentSnapshot?.bundlePath ? owningActionApp(agentSnapshot.bundlePath) : undefined;
  const paths = await findActionCopies([hostApp, ...(agentApp ? [agentApp] : [])]);
  const copies = await Promise.all(paths.map(inspectBundleSigning));
  const signing = (path: string | undefined) => {
    if (!path) return undefined;
    const canonical = canonicalPath(path);
    return copies.find((copy) => copy.path === canonical);
  };

  return diagnosePermissions({
    agent: agentSnapshot ? { ...agentSnapshot, app: signing(agentApp) } : undefined,
    agentError,
    host: hostDiagnostics ? { ...hostDiagnostics, app: signing(hostApp) } : undefined,
    copies,
  });
}
