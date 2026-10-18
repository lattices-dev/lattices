import { assertLayerSafety } from "./layer-safety.js";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { promisify } from "node:util";

import type {
  AgentLayerOwner,
  AgentLayerState,
  AgentLayerStatus,
  AgentLayerSubject,
} from "@action/protocol";

import type { AgentLayerRouting } from "./interaction/index.js";
import { withWorkspaceLock } from "./workspace-lock.js";

const execFileAsync = promisify(execFile);

const DEFAULT_OWNER: AgentLayerOwner = "caller";
const STATE_POLL_MS = 40;
const DEFAULT_STATE_WAIT_MS = 3000;
const DEFAULT_CLOSE_WAIT_MS = 3000;
const SIGTERM_WAIT_MS = 1500;
const CONTROL_WAIT_MS = 1500;
const RECORD_WAIT_MS = 5000;
const workspaceMutations = new Map<string, Promise<unknown>>();

export type AgentLayerHostRunner = (args: string[]) => Promise<{ stdout: string }>;

export interface AgentLayerDisplayState {
  schemaVersion: 1;
  workspace?: string;
  pid: number;
  displayId: number;
  startedAt: string;
  width: number;
  height: number;
  serialNumber: number;
}

export interface AgentLayerDisplayStatus {
  workspace: string;
  active: boolean;
  state: "ready" | "missing" | "stale" | "invalid";
  display?: AgentLayerDisplayState;
  stateFile: string;
  stopFile: string;
  detail?: string;
}

export interface AgentLayerOpenInput {
  previewDisplayId?: number;
  previewFull?: boolean;
  bundleId?: string;
  pid?: number;
  width?: number;
  height?: number;
  pip?: boolean;
  /** Move only this window (CGWindowID / kCGWindowNumber) instead of all the app's windows. */
  windowId?: number;
  /** Move only windows whose title contains this, case-insensitively. */
  windowTitle?: string;
  /**
   * Open this in the subject app without activating it, once its windows are on the
   * layer. A bare host reads as https. Needs bundleId or pid.
   */
  url?: string;
  /**
   * Don't ask the app for a window when it has none: the caller makes one itself, right
   * on the layer (a browser through DevTools). Windows that appear are still adopted.
   */
  windowless?: boolean;
  owner?: AgentLayerOwner;
}

export interface AgentLayerMark {
  kind: "aim" | "click" | "drag" | "scroll" | "field";
  point?: { x: number; y: number };
  from?: { x: number; y: number };
  frame?: { x: number; y: number; width: number; height: number };
  dy?: number;
}

export interface AgentLayerSnapshotInput {
  /** Crop to this window (kCGWindowNumber). Must be on the layer. */
  windowId?: number;
  /** The whole layer instead of the subject's windows. */
  full?: boolean;
  /** PNG path. Defaults to the layer's snapshots folder. */
  out?: string;
}

export interface AgentLayerSnapshot {
  ok: boolean;
  path?: string;
  width?: number;
  height?: number;
  /** Display-local points on the layer. */
  crop?: { x: number; y: number; width: number; height: number };
  windowId?: number | null;
  /** Time since the layer last changed: the frame is current, this is how long it's been still. */
  unchangedMs?: number;
  detail?: string;
}

/** Sidecar the director writes next to the native state file: who asked, and for what. */
interface AgentLayerRequest {
  owner: AgentLayerOwner;
  ownerPid?: number;
  subject?: AgentLayerSubject;
  pid?: number;
  startedAt?: string;
}

export interface AgentLayerDirectorOptions {
  root?: string;
  workspace?: string;
  runHost?: AgentLayerHostRunner;
  /** Liveness probe. Defaults to `process.kill(pid, 0)`. */
  isAlive?: (pid: number) => boolean;
  /** Sends SIGTERM. Defaults to `process.kill(pid, "SIGTERM")`. */
  terminate?: (pid: number) => void;
  stateWaitMs?: number;
  closeWaitMs?: number;
  safetyPath?: string;
}

export function parseAgentWorkspace(value: unknown = "default"): string {
  if (typeof value !== "string" || value.trim() !== value || !/^[a-z][a-z0-9-]{0,31}$/.test(value)) {
    throw new Error("workspace must be 1–32 lowercase letters, digits, or hyphens, starting with a letter");
  }
  return value;
}

export function agentWorkspaceSerial(workspace: string): number {
  const name = parseAgentWorkspace(workspace);
  if (name === "default") return 0x41435401;
  let hash = 2166136261;
  for (const byte of new TextEncoder().encode(name)) hash = Math.imul(hash ^ byte, 16777619) >>> 0;
  return (hash | 0x80000000) >>> 0;
}

export function agentLayerStateDir(workspace = "default"): string {
  const root = resolve(homedir(), "Library/Application Support/Action/agent-layer");
  return workspaceStateDir(root, parseAgentWorkspace(workspace));
}

function workspaceStateDir(root: string, workspace: string): string {
  return workspace === "default" ? root : resolve(root, "workspaces", workspace);
}

export async function agentLayerWorkspaces(root = agentLayerStateDir()): Promise<string[]> {
  try {
    const entries = await readdir(resolve(root, "workspaces"), { withFileTypes: true });
    return ["default", ...entries.filter(entry => entry.isDirectory() && entry.name !== "default"
      && /^[a-z][a-z0-9-]{0,31}$/.test(entry.name)).map(entry => entry.name).sort()];
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return ["default"];
    throw error;
  }
}

export function parseAgentLayerOpen(input: {
  bundleId?: unknown;
  pid?: unknown;
  width?: unknown;
  height?: unknown;
  pip?: unknown;
  windowId?: unknown;
  windowTitle?: unknown;
  url?: unknown;
  owner?: unknown;
  windowless?: unknown;
  previewDisplayId?: unknown;
  previewFull?: unknown;
}): AgentLayerOpenInput {
  const bundleId = typeof input.bundleId === "string" && input.bundleId.trim() ? input.bundleId.trim() : undefined;
  const pid = optionalPositiveInt(input.pid, "pid");
  if (bundleId && pid !== undefined) {
    throw new Error("Pass bundleId or pid, not both");
  }
  const width = optionalPositiveInt(input.width, "width");
  const height = optionalPositiveInt(input.height, "height");
  if ((width === undefined) !== (height === undefined)) {
    throw new Error("width and height go together");
  }
  const pip = input.pip === undefined || input.pip === null ? undefined : input.pip !== false && input.pip !== "off" && input.pip !== "false";
  const windowId = optionalPositiveInt(input.windowId, "windowId");
  const windowTitle = typeof input.windowTitle === "string" && input.windowTitle.trim() ? input.windowTitle.trim() : undefined;
  const url = typeof input.url === "string" && input.url.trim() ? input.url.trim() : undefined;
  if (url && !bundleId && pid === undefined) {
    throw new Error('url needs the app to open it in: pass bundleId too, e.g. "com.apple.Safari"');
  }
  if (url && (windowId !== undefined || windowTitle)) {
    // The app picks the window a URL lands in, which may be one the operator still has.
    throw new Error("url opens in the app's front window, so it can't be combined with windowId or windowTitle");
  }
  const owner: AgentLayerOwner = input.owner === "detached" ? "detached" : DEFAULT_OWNER;
  const previewDisplayId = optionalPositiveInt(input.previewDisplayId, "previewDisplayId");
  if (input.previewFull !== undefined && typeof input.previewFull !== "boolean") throw new Error("previewFull must be a boolean");
  if (previewDisplayId !== undefined && previewDisplayId > 0xffffffff) throw new Error("previewDisplayId must be a display identifier");
  return {
    ...(bundleId ? { bundleId } : {}),
    ...(pid !== undefined ? { pid } : {}),
    ...(width !== undefined ? { width, height } : {}),
    ...(pip !== undefined ? { pip } : {}),
    ...(windowId !== undefined ? { windowId } : {}),
    ...(windowTitle ? { windowTitle } : {}),
    ...(url ? { url } : {}),
    ...(input.windowless === true ? { windowless: true } : {}),
    ...(previewDisplayId !== undefined ? { previewDisplayId } : {}),
    ...(input.previewFull !== undefined ? { previewFull: input.previewFull as boolean } : {}),
    owner,
  };
}

function optionalPositiveInt(value: unknown, name: string): number | undefined {
  if (value === undefined || value === null || value === "") {
    return undefined;
  }
  const number = Number(value);
  if (!Number.isInteger(number) || number <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return number;
}

/** The layer's app: the requested subject, else the first window that moved onto it. */
export function agentLayerSubject(status: AgentLayerStatus): AgentLayerSubject | undefined {
  if (status.subject?.bundleId || status.subject?.pid) {
    return status.subject;
  }
  const first = status.layer?.windows[0];
  if (!first) {
    return undefined;
  }
  return first.bundleId ? { bundleId: first.bundleId } : { pid: first.pid };
}

/** What the interaction router needs from a status, or undefined when no layer is up. */
export function agentLayerRouting(status: AgentLayerStatus): AgentLayerRouting | undefined {
  if (!status.active || !status.layer) {
    return undefined;
  }
  const subject = agentLayerSubject(status);
  return {
    ...(subject?.bundleId ? { bundleId: subject.bundleId } : {}),
    ...(subject?.pid ? { pid: subject.pid } : {}),
    bounds: status.layer.bounds,
  };
}

function defaultIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function defaultTerminate(pid: number): void {
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    // Already gone.
  }
}

export class AgentLayerDirector {
  readonly workspace: string;
  private readonly registryRoot: string;
  private readonly root: string;
  private readonly runHost: AgentLayerHostRunner;
  private readonly isAlive: (pid: number) => boolean;
  private readonly terminate: (pid: number) => void;
  private readonly stateWaitMs: number;
  private readonly closeWaitMs: number;
  private readonly safetyPath?: string;

  constructor(
    private readonly nativeHostPath: string,
    options: AgentLayerDirectorOptions = {},
  ) {
    this.workspace = parseAgentWorkspace(options.workspace);
    this.registryRoot = options.root ?? agentLayerStateDir();
    this.root = workspaceStateDir(this.registryRoot, this.workspace);
    this.runHost = options.runHost ?? ((args) => execFileAsync(this.nativeHostPath, args));
    this.isAlive = options.isAlive ?? defaultIsAlive;
    this.terminate = options.terminate ?? defaultTerminate;
    this.stateWaitMs = options.stateWaitMs ?? DEFAULT_STATE_WAIT_MS;
    this.closeWaitMs = options.closeWaitMs ?? DEFAULT_CLOSE_WAIT_MS;
    this.safetyPath = options.safetyPath;
  }

  paths() {
    return {
      stop: resolve(this.root, "layer.stop"),
      state: resolve(this.root, "state.json"),
      request: resolve(this.root, "request.json"),
      log: resolve(this.root, "layer.log"),
      controlRequest: resolve(this.root, "control.request.json"),
      controlReply: resolve(this.root, "control.reply.json"),
      handoff: resolve(this.root, "handoff.json"),
      displayState: resolve(this.root, "display.json"),
      displayStop: resolve(this.root, "display.stop"),
      displayLog: resolve(this.root, "display.log"),
    };
  }

  async displayStatus(): Promise<AgentLayerDisplayStatus> {
    const paths = this.paths();
    const base = { workspace: this.workspace, stateFile: paths.displayState, stopFile: paths.displayStop };
    let parsed: AgentLayerDisplayState;
    try {
      parsed = JSON.parse(await readFile(paths.displayState, "utf8")) as AgentLayerDisplayState;
    } catch (error) {
      return (error as NodeJS.ErrnoException).code === "ENOENT"
        ? { ...base, active: false, state: "missing" }
        : { ...base, active: false, state: "invalid", detail: "Prepared display manifest is unreadable or invalid JSON." };
    }
    if (!parsed || parsed.schemaVersion !== 1 || !positiveInteger(parsed.pid) || parsed.pid <= 1 || !unsignedID(parsed.displayId)
      || !positiveInteger(parsed.width) || parsed.width < 640 || parsed.width > 8192 || !positiveInteger(parsed.height) || parsed.height < 400 || parsed.height > 8192
      || parsed.serialNumber !== agentWorkspaceSerial(this.workspace) || (parsed.workspace ?? "default") !== this.workspace
      || typeof parsed.startedAt !== "string" || !Number.isFinite(Date.parse(parsed.startedAt))) {
      return { ...base, active: false, state: "invalid", detail: "Prepared display manifest has invalid identity or dimensions." };
    }
    return this.isAlive(parsed.pid)
      ? { ...base, active: true, state: "ready", display: parsed }
      : { ...base, active: false, state: "stale", display: parsed, detail: "Prepared display owner is no longer running." };
  }

  prepareDisplay(input: { width?: unknown; height?: unknown } = {}): Promise<AgentLayerDisplayStatus> {
    return this.serialize(async () => {
      const size = parseAgentLayerOpen({ width: input.width, height: input.height });
      if ((size.width !== undefined && size.width < 640) || (size.height !== undefined && size.height < 400)) {
        throw new Error("Prepared display must be at least 640x400");
      }
      if ((size.width !== undefined && size.width > 8192) || (size.height !== undefined && size.height > 8192)) {
        throw new Error("Prepared display dimensions must not exceed 8192");
      }
      const existing = await this.displayStatus();
      if (existing.state === "invalid") throw new Error(existing.detail);
      if (existing.active && existing.display) {
        this.assertDisplaySize(existing.display, size);
        return existing;
      }
      if ((await this.status()).active) throw new Error("Close the active agent layer before preparing a display");
      assertLayerSafety(this.safetyPath);
      const paths = this.paths();
      await mkdir(this.root, { recursive: true });
      await rm(paths.displayStop, { force: true });
      const width = size.width ?? 1440;
      const height = size.height ?? 900;
      const { stdout } = await this.runHost([
        "agent-display", "--state-file", paths.displayState, "--stop-file", paths.displayStop,
        "--workspace", this.workspace,
        "--debug-log", paths.displayLog, "--width", String(width), "--height", String(height),
      ]);
      const response = JSON.parse(stdout.trim() || "{}") as { status?: string; detail?: string };
      const pid = Number(response.detail);
      if (response.status !== "agent-display-running" || !positiveInteger(pid) || pid <= 1) {
        throw new Error(`agent-display did not start: ${response.detail ?? response.status ?? "no reply"}`);
      }
      const deadline = Date.now() + this.stateWaitMs;
      try {
        for (;;) {
          const status = await this.displayStatus();
          if (status.active && status.display) {
            if (status.display.pid !== pid) throw new Error("Prepared display owner changed during setup; refusing to use a different display");
            this.assertDisplaySize(status.display, { width, height });
            return status;
          }
          if (status.state === "invalid") throw new Error(status.detail);
          if (Date.now() >= deadline) throw new Error("agent-display replied but never wrote a live prepared display manifest");
          await delay(STATE_POLL_MS);
        }
      } catch (error) {
        throw new Error(`${error instanceof Error ? error.message : String(error)}. Setup owner PID ${pid} may still be running; inspect display status before retrying. No display owner was removed.`);
      }
    });
  }

  releaseDisplay(): Promise<AgentLayerDisplayStatus> {
    return this.serialize(async () => {
      const current = await this.displayStatus();
      if (current.state === "invalid") throw new Error(current.detail);
      if ((await this.status()).active) throw new Error("Close the active task explicitly before release; refusing to release its prepared display");
      if (!current.active || !current.display) return current;
      for (const workspace of await agentLayerWorkspaces(this.registryRoot)) {
        const state = await readJson<AgentLayerState>(resolve(workspaceStateDir(this.registryRoot, workspace), "state.json"));
        if (state?.pip && state.previewDisplayId === current.display.displayId && this.isAlive(state.pid)) {
          throw new Error(`Close the ${workspace} preview before releasing workspace ${this.workspace}`);
        }
      }
      const latest = await this.requirePreparedDisplay();
      this.assertSameDisplay(current.display, latest);
      await writeFile(this.paths().displayStop, "stop\n");
      if (!await this.waitForExit(current.display.pid, this.closeWaitMs)) {
        throw new Error("Prepared display owner did not exit; display remains prepared. No forced display removal was attempted.");
      }
      const remaining = await this.displayStatus();
      if (remaining.display) {
        this.assertSameDisplay(current.display, remaining.display);
        await rm(this.paths().displayState, { force: true });
      }
      await rm(this.paths().displayStop, { force: true });
      return this.displayStatus();
    });
  }

  open(input: Parameters<typeof parseAgentLayerOpen>[0] = {}): Promise<AgentLayerStatus> {
    return this.serialize(() => this.openSession(input));
  }

  private async openSession(input: Parameters<typeof parseAgentLayerOpen>[0]): Promise<AgentLayerStatus> {
    const request = parseAgentLayerOpen(input);
    const display = await this.requirePreparedDisplay();
    this.assertDisplaySize(display, request);
    if (request.previewDisplayId !== undefined) await this.validatePreviewDestination(display.displayId, request.previewDisplayId);
    const owner = request.owner ?? DEFAULT_OWNER;
    if ((await this.status()).active) throw new Error(`Workspace ${this.workspace} already has an active task; close it explicitly before opening another`);

    const paths = this.paths();
    await mkdir(this.root, { recursive: true });
    await rm(paths.handoff, { force: true });
    await rm(paths.stop, { force: true });
    await rm(paths.state, { force: true });
    await rm(paths.log, { force: true });

    this.assertSameDisplay(display, await this.requirePreparedDisplay());
    const args = ["agent-layer", "--stop-file", paths.stop, "--state-file", paths.state, "--debug-log", paths.log,
      "--display-id", String(display.displayId), "--display-owner-pid", String(display.pid),
      "--display-started-at", display.startedAt, "--display-state-file", paths.displayState];
    args.push("--workspace", this.workspace);
    if (request.previewDisplayId !== undefined) args.push("--preview-display-id", String(request.previewDisplayId));
    if (request.previewFull !== undefined) args.push("--preview-full", String(request.previewFull));
    // Same rule as the stage drape: a caller-owned layer watches this process and
    // restores the windows if it dies. A one-shot CLI exits right after open, so it
    // asks for `detached` and relies on `layer close`.
    if (owner === "caller") {
      args.push("--parent-pid", String(process.pid));
    }
    // Where the viewer's "go to owner" goes. A detached CLI is gone by then, so the
    // chain is taken now.
    const owners = await processAncestry(process.pid);
    if (owners.length > 0) {
      args.push("--owner-pids", owners.join(","));
    }
    if (request.bundleId) {
      args.push("--bundle-id", request.bundleId);
    } else if (request.pid !== undefined) {
      args.push("--pid", String(request.pid));
    }
    if (request.width !== undefined && request.height !== undefined) {
      args.push("--width", String(request.width), "--height", String(request.height));
    }
    if (request.pip !== undefined) {
      args.push("--pip", request.pip ? "on" : "off");
    }
    if (request.windowId !== undefined) {
      args.push("--window-id", String(request.windowId));
    }
    if (request.windowTitle) {
      args.push("--window-title", request.windowTitle);
    }
    if (request.url) {
      args.push("--url", request.url);
    }
    if (request.windowless) {
      args.push("--windowless", "1");
    }

    const subject: AgentLayerSubject | undefined = request.bundleId
      ? { bundleId: request.bundleId }
      : request.pid !== undefined
        ? { pid: request.pid }
        : undefined;
    let replyPid: number | undefined;
    try {
      const { stdout } = await this.runHost(args);
      const response = JSON.parse(stdout.trim() || "{}") as { status?: string; detail?: string };
      if (response.status !== "agent-layer-running") {
        throw new Error(`agent-layer did not start: ${response.detail ?? response.status ?? "no reply"}`);
      }
      const parsedPid = Number(response.detail);
      if (!positiveInteger(parsedPid) || parsedPid <= 1 || parsedPid === display.pid) {
        throw new Error("Agent layer reply does not identify a distinct session process");
      }
      replyPid = parsedPid;
      const sidecar: AgentLayerRequest = {
        owner,
        ...(owner === "caller" ? { ownerPid: process.pid } : {}),
        ...(subject ? { subject } : {}),
        pid: replyPid,
      };
      await writeFile(paths.request, `${JSON.stringify(sidecar, null, 2)}\n`);
      const state = await this.waitForState(this.stateWaitMs);
      if (!state) throw new Error("agent-layer replied but never wrote its state file");
      if (state.pid !== replyPid || state.displayId !== display.displayId || !this.isAlive(state.pid)) {
        throw new Error("Agent layer state does not match the new session and prepared display identities");
      }
      sidecar.startedAt = state.startedAt;
      await writeFile(paths.request, `${JSON.stringify(sidecar, null, 2)}\n`);
      this.assertSameDisplay(display, await this.requirePreparedDisplay());
      return this.describe(sidecar, state, true);
    } catch (error) {
      let cleanup = "Session ownership is unconfirmed; inspect layer status before cleanup. The prepared display was retained.";
      if (replyPid) {
        const currentRequest = await this.readRequest();
        const currentState = await readJson<{ pid?: number; startedAt?: string }>(paths.state);
        if (currentRequest?.pid === replyPid && (!currentState || currentState.pid === replyPid)
          && (!currentRequest.startedAt || !currentState || currentState.startedAt === currentRequest.startedAt)) {
          try {
            const closed = await this.closeSession();
            cleanup = closed.active ? `Session PID ${replyPid} could not close; inspect layer status. The prepared display was retained.`
              : `Created session PID ${replyPid} was closed. The prepared display was retained.`;
          } catch {
            cleanup = `Session PID ${replyPid} cleanup could not be confirmed; inspect layer status. The prepared display was retained.`;
          }
        } else {
          cleanup = `Session identity changed; refusing to close a replacement. Created PID ${replyPid} may remain running. The prepared display was retained.`;
        }
      }
      throw new Error(`${error instanceof Error ? error.message : String(error)} ${cleanup}`);
    }
  }

  close(expected?: Pick<AgentLayerState, "pid" | "displayId" | "startedAt">): Promise<AgentLayerStatus> {
    return this.serialize(async () => {
      if (expected) {
        const current = await this.status();
        if (current.active && (!current.layer || current.layer.pid !== expected.pid
          || current.layer.displayId !== expected.displayId || current.layer.startedAt !== expected.startedAt)) {
          throw new Error("Agent layer ownership changed; refusing to close a replacement session");
        }
      }
      return this.closeSession();
    });
  }

  private async closeSession(): Promise<AgentLayerStatus> {
    const paths = this.paths();
    const request = await this.readRequest();
    const state = await this.readState();
    if (request?.pid && state?.pid && (request.pid !== state.pid || (request.startedAt && request.startedAt !== state.startedAt))) {
      throw new Error("Agent layer state and request identify different sessions; refusing to stop a replacement session");
    }
    const pid = state?.pid ?? request?.pid;
    const owner = request?.owner ?? DEFAULT_OWNER;

    if (!pid && !state && !request) {
      return { active: false, owner, workspace: this.workspace };
    }

    await mkdir(this.root, { recursive: true });
    await writeFile(paths.stop, "stop\n");

    let gone = pid ? await this.waitForExit(pid, this.closeWaitMs) : true;
    if (!gone && pid) {
      this.terminate(pid);
      gone = await this.waitForExit(pid, SIGTERM_WAIT_MS);
    }

    if (gone) {
      await rm(paths.state, { force: true });
      await rm(paths.request, { force: true });
      await rm(paths.stop, { force: true });
    }
    return {
      // A layer still up after the stop file and SIGTERM holds the user's windows.
      // Report it rather than calling it closed.
      active: !gone,
      workspace: this.workspace,
      owner,
      ...(request?.subject ? { subject: request.subject } : {}),
      ...(gone ? {} : { pid }),
    };
  }

  /** Brings the PiP viewer back after the user dismissed it. The layer itself never stopped. */
  async showViewer(input: { previewDisplayId?: number; previewFull?: boolean } = {}): Promise<AgentLayerStatus> {
    return this.serialize(() => this.showViewerSession(input));
  }

  private async showViewerSession(input: { previewDisplayId?: number; previewFull?: boolean }): Promise<AgentLayerStatus> {
    const status = await this.status();
    if (!status.active || !status.layer) {
      throw new Error("No agent layer is up");
    }
    if (input.previewFull !== undefined && typeof input.previewFull !== "boolean") throw new Error("previewFull must be a boolean");
    if (input.previewDisplayId !== undefined || input.previewFull !== undefined) {
      if (input.previewDisplayId !== undefined) {
        if (!unsignedID(input.previewDisplayId)) throw new Error("previewDisplayId must be a display identifier");
        await this.validatePreviewDestination(status.layer.displayId, input.previewDisplayId);
      }
      await this.sendControl("show", { ...input }, CONTROL_WAIT_MS);
      return this.status();
    }
    if (!status.layer.pip) {
      process.kill(status.layer.pid, "SIGUSR1");
      const deadline = Date.now() + 1000;
      while (Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 50));
        const next = await this.status();
        if (next.layer?.pip) {
          return next;
        }
      }
    }
    return this.status();
  }

  /**
   * A PNG of one window on the layer (or the subject's windows, or the whole layer),
   * cut from the layer's running feed. Nothing is captured on request: the layer
   * already holds the current frame, so this answers in milliseconds.
   */
  async snapshot(input: AgentLayerSnapshotInput = {}): Promise<AgentLayerSnapshot> {
    const out = resolve(input.out ?? resolve(this.root, "snapshots", `layer-${Date.now()}.png`));
    return this.control<AgentLayerSnapshot>("snapshot", {
      out,
      ...(input.windowId !== undefined ? { windowId: input.windowId } : {}),
      full: input.full === true,
    });
  }

  /**
   * Record the layer to a movie off the same running feed the viewer shows, so the
   * take starts on the next frame. One take at a time; `stopRecording` finishes it.
   */
  async startRecording(input: { out?: string } = {}): Promise<{ ok: boolean; path?: string }> {
    const out = resolve(input.out ?? resolve(this.root, "recordings", `layer-${Date.now()}.mov`));
    return this.control("record-start", { out }, RECORD_WAIT_MS);
  }

  async stopRecording(): Promise<{ ok: boolean; path?: string }> {
    return this.control("record-stop", {}, RECORD_WAIT_MS);
  }

  /**
   * Show an act on the viewer, for acts the layer's host did not run (DevTools input
   * into a browser on the layer): the pointer gliding to it, a press, a trail, a field
   * lighting up. Global top-left points.
   */
  async mark(act: AgentLayerMark): Promise<void> {
    await this.control("mark", {
      kind: act.kind,
      ...(act.point ? { x: act.point.x, y: act.point.y } : {}),
      ...(act.from ? { fromX: act.from.x, fromY: act.from.y } : {}),
      ...(act.frame ? { fx: act.frame.x, fy: act.frame.y, fw: act.frame.width, fh: act.frame.height } : {}),
      ...(act.dy !== undefined ? { dy: act.dy } : {}),
    });
  }

  /** Leaves a request next to the state file, signals the layer, and waits for its reply. */
  private async control<T extends { ok: boolean; detail?: string }>(
    op: string,
    payload: Record<string, unknown>,
    budgetMs = CONTROL_WAIT_MS,
  ): Promise<T> {
    return this.serialize(() => this.sendControl<T>(op, payload, budgetMs));
  }

  private async sendControl<T extends { ok: boolean; detail?: string }>(op: string, payload: Record<string, unknown>, budgetMs: number): Promise<T> {
    const status = await this.status();
    if (!status.active || !status.layer) {
      throw new Error("No agent layer is up");
    }
    const paths = this.paths();
    const id = randomUUID();
    await rm(paths.controlReply, { force: true });
    await writeFile(paths.controlRequest, `${JSON.stringify({ id, op, ...payload })}\n`);
    process.kill(status.layer.pid, "SIGUSR2");
    const deadline = Date.now() + budgetMs;
    for (;;) {
      const reply = await readJson<T & { id?: string }>(paths.controlReply);
      if (reply?.id === id) {
        const { id: _id, ...result } = reply;
        if (!result.ok) {
          throw new Error(`agent-layer ${op} failed: ${result.detail ?? "no detail"}`);
        }
        return result as unknown as T;
      }
      if (Date.now() >= deadline) {
        throw new Error(`agent-layer did not answer ${op}`);
      }
      await delay(10);
    }
  }

  /** The live layer, or an inactive status. */
  async status(): Promise<AgentLayerStatus> {
    const request = await this.readRequest();
    const state = await this.readState();
    const owner = request?.owner ?? DEFAULT_OWNER;
    const pid = state?.pid ?? request?.pid;
    if (!pid) {
      return { active: false, owner, workspace: this.workspace };
    }
    if (!this.isAlive(pid)) {
      return { active: false, owner, workspace: this.workspace };
    }
    if (!state) {
      // Alive but no state yet (still starting, or state lost). Closable, not routable.
      return {
        active: true,
        workspace: this.workspace,
        owner,
        pid,
        ...(request?.subject ? { subject: request.subject } : {}),
        stopFile: this.paths().stop,
      };
    }
    return this.describe(request ?? { owner }, state, true);
  }

  /**
   * Why an agent act must not run right now, or undefined when it may: the operator
   * paused the layer from its viewer, or took the windows back.
   */
  async actRefusal(): Promise<string | undefined> {
    const status = await this.status();
    const handoff = await readJson<{ at?: string; action?: string; pid?: number; displayId?: number; startedAt?: string }>(this.paths().handoff);
    if (handoff && (!status.active || !handoff.pid || (status.layer?.pid === handoff.pid
      && status.layer.displayId === handoff.displayId && status.layer.startedAt === handoff.startedAt))) {
      const action = handoff.action === "stop" ? "stopped" : "took over";
      return `The operator ${action} the agent layer from its preview${handoff.at ? ` at ${handoff.at}` : ""}. Stop interactions and report this to the user. A new session requires fresh user authorization.`;
    }
    if (status.active && status.layer?.paused) {
      return "The operator paused the agent layer from its viewer. Wait for them to resume it.";
    }
    return undefined;
  }

  /** Routing input for the interaction layer, or undefined when no layer is up. */
  async routing(): Promise<AgentLayerRouting | undefined> {
    return agentLayerRouting(await this.status());
  }

  private describe(request: AgentLayerRequest, state: AgentLayerState, active: boolean): AgentLayerStatus {
    const paths = this.paths();
    return {
      active,
      workspace: this.workspace,
      owner: request.owner,
      ...(request.ownerPid ? { ownerPid: request.ownerPid } : {}),
      ...(request.subject ? { subject: request.subject } : {}),
      stopFile: paths.stop,
      stateFile: paths.state,
      layer: state,
    };
  }

  private async waitForState(budgetMs: number): Promise<AgentLayerState | undefined> {
    const deadline = Date.now() + budgetMs;
    for (;;) {
      const state = await this.readState();
      if (state) {
        return state;
      }
      if (Date.now() >= deadline) {
        return undefined;
      }
      await delay(STATE_POLL_MS);
    }
  }

  private async waitForExit(pid: number, budgetMs: number): Promise<boolean> {
    const deadline = Date.now() + budgetMs;
    for (;;) {
      if (!this.isAlive(pid)) {
        return true;
      }
      if (Date.now() >= deadline) {
        return false;
      }
      await delay(STATE_POLL_MS);
    }
  }

  private async readState(): Promise<AgentLayerState | undefined> {
    const parsed = await readJson<AgentLayerState>(this.paths().state);
    if (parsed && (parsed.workspace ?? "default") !== this.workspace) {
      throw new Error("Agent layer state belongs to a different workspace");
    }
    return parsed && positiveInteger(parsed.pid) && parsed.pid > 1 && unsignedID(parsed.displayId)
      && typeof parsed.startedAt === "string" && Number.isFinite(Date.parse(parsed.startedAt))
      && parsed.bounds && [parsed.bounds.x, parsed.bounds.y, parsed.bounds.width, parsed.bounds.height].every(Number.isFinite)
      && parsed.bounds.width > 0 && parsed.bounds.height > 0 ? parsed : undefined;
  }

  private async readRequest(): Promise<AgentLayerRequest | undefined> {
    return readJson<AgentLayerRequest>(this.paths().request);
  }

  private async requirePreparedDisplay(): Promise<AgentLayerDisplayState> {
    const status = await this.displayStatus();
    if (!status.active || !status.display) {
      throw new Error(`No prepared agent display is available (${status.state}). Run explicit display preparation before opening a session.${status.detail ? ` ${status.detail}` : ""}`);
    }
    return status.display;
  }

  private assertDisplaySize(display: AgentLayerDisplayState, size: { width?: number; height?: number }): void {
    if (size.width !== undefined && (size.width !== display.width || size.height !== display.height)) {
      throw new Error(`Prepared display is ${display.width}x${display.height}; release and explicitly prepare a new display to change its dimensions`);
    }
  }

  private assertSameDisplay(expected: AgentLayerDisplayState, actual: AgentLayerDisplayState): void {
    if (expected.pid !== actual.pid || expected.displayId !== actual.displayId || expected.startedAt !== actual.startedAt || expected.serialNumber !== actual.serialNumber
      || expected.width !== actual.width || expected.height !== actual.height) {
      throw new Error("Prepared display identity changed during the operation");
    }
  }

  private async validatePreviewDestination(source: number, destination: number): Promise<void> {
    const edges = new Map<number, number>();
    for (const workspace of await agentLayerWorkspaces(this.registryRoot)) {
      const state = await readJson<AgentLayerState>(resolve(workspaceStateDir(this.registryRoot, workspace), "state.json"));
      if (state && state.pip && this.isAlive(state.pid) && unsignedID(state.previewDisplayId)) edges.set(state.displayId, state.previewDisplayId);
    }
    const visited = new Set<number>([source]);
    let next: number | undefined = destination;
    while (next !== undefined) {
      if (visited.has(next)) throw new Error("Preview destination would create a recursive workspace preview");
      visited.add(next);
      next = edges.get(next);
    }
  }

  private serialize<Result>(operation: () => Promise<Result>): Promise<Result> {
    const result = (workspaceMutations.get(this.root) ?? Promise.resolve()).then(() => withWorkspaceLock(resolve(this.root, "transaction.lock"), operation));
    const tail = result.catch(() => undefined);
    workspaceMutations.set(this.root, tail);
    void tail.then(() => { if (workspaceMutations.get(this.root) === tail) workspaceMutations.delete(this.root); });
    return result;
  }
}

function positiveInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function unsignedID(value: unknown): value is number {
  return positiveInteger(value) && value <= 0xffffffff;
}

/** `pid` and its parents, nearest first, stopping before launchd. */
async function processAncestry(pid: number): Promise<number[]> {
  let table: string;
  try {
    ({ stdout: table } = await execFileAsync("/bin/ps", ["-A", "-o", "pid=,ppid="]));
  } catch {
    return [pid];
  }
  const parents = new Map<number, number>();
  for (const line of table.split("\n")) {
    const [child, parent] = line.trim().split(/\s+/).map(Number);
    if (child && parent !== undefined) {
      parents.set(child, parent);
    }
  }
  const chain: number[] = [];
  for (let current = pid; current > 1 && chain.length < 16; current = parents.get(current) ?? 0) {
    chain.push(current);
  }
  return chain;
}

async function readJson<T>(path: string): Promise<T | undefined> {
  try {
    return JSON.parse(await readFile(path, "utf8")) as T;
  } catch {
    return undefined;
  }
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolveWait) => setTimeout(resolveWait, milliseconds));
}
