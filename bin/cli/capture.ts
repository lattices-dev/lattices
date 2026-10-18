import {
  hasFlag,
  nonFlagArgs,
  parseFlagValue,
  parseOptionalNumber,
} from "./helpers.ts";
import { remoteHostName, withDaemon } from "./daemon.ts";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, join, resolve } from "node:path";

const CAPTURE_AUDIT_FILE = join(homedir(), ".lattices/audit/captures.jsonl");

/** Print the screenshots agents took over the daemon socket, newest last. */
function captureLog(args: string[]): void {
  const limit = Number(parseFlagValue(args, "limit") || 20) || 20;
  const lines = existsSync(CAPTURE_AUDIT_FILE)
    ? readFileSync(CAPTURE_AUDIT_FILE, "utf8").split("\n").filter(Boolean)
    : [];
  const entries = lines.slice(-Math.max(1, limit)).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
  if (hasFlag(args, "json")) {
    console.log(JSON.stringify(entries, null, 2));
    return;
  }
  if (entries.length === 0) {
    console.log(`No agent screenshots logged yet (${CAPTURE_AUDIT_FILE}).`);
    return;
  }
  for (const e of entries) {
    const caller = e.caller ?? {};
    const when = new Date(e.ts).toLocaleString();
    const who = caller.agent || caller.client || "unknown";
    const from = !caller.origin || caller.origin === "local" ? "local" : caller.origin;
    const project = caller.cwd ? basename(caller.cwd) : "";
    const what = [e.kind, e.target?.app, e.display].filter(Boolean).join(" · ");
    console.log(`${when}  ${who}  ${from}${project ? `  ${project}` : ""}  ${what}`);
    if (e.artifact) console.log(`  ${e.artifact}`);
  }
}

export type CaptureDisplayArgs = {
  display?: number;
  clipboard: boolean;
  delaySeconds: number;
  filename?: string;
  out?: string;
  runId?: string;
  json: boolean;
};

/** Where a capture from another host lands on this Mac. */
export function remoteCapturePath(
  host: string,
  kind: string,
  format: string,
  options: { out?: string; filename?: string; now?: Date } = {},
): string {
  if (options.out) return resolve(options.out);
  const ext = format === "jpeg" || format === "jpg" ? "jpg" : "png";
  const stamp = (options.now ?? new Date()).toISOString().replace(/[:.]/gu, "-").replace(/Z$/u, "");
  const name = options.filename ? basename(options.filename) : `${host}-${kind}-${stamp}.${ext}`;
  return join(homedir(), ".lattices/captures", host, extname(name) ? name : `${name}.${ext}`);
}

/**
 * Save an inline capture from another host here. A host that can't return the
 * image (a Mac daemon writes its captures to its own disk) keeps the remote path.
 */
async function saveRemoteCapture(
  host: string,
  kind: string,
  result: any,
  options: { out?: string; filename?: string; clipboard?: boolean; json?: boolean },
): Promise<void> {
  const remotePath = result.path ?? result.artifact?.path;
  if (typeof result.data !== "string") {
    if (options.json) { console.log(JSON.stringify(result, null, 2)); return; }
    console.log(`Captured ${kind.replace("-", " ")} on ${host}; ${host} kept the image.`);
    console.log(`  ${host}: ${remotePath ?? "?"}`);
    return;
  }
  const format = result.format ?? "png";
  const path = remoteCapturePath(host, kind, format, options);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, Buffer.from(result.data, "base64"));

  let copied: boolean | undefined;
  if (options.clipboard) {
    const cls = format === "jpeg" || format === "jpg" ? "JPEG" : "PNGf";
    const proc = Bun.spawnSync(["osascript", "-e", `set the clipboard to (read (POSIX file ${JSON.stringify(path)}) as «class ${cls}»)`]);
    copied = proc.exitCode === 0;
  }

  const { data: _data, ...rest } = result;
  if (options.json) {
    console.log(JSON.stringify({ ...rest, host, path, remotePath, clipboard: copied === undefined ? undefined : { copied } }, null, 2));
    return;
  }
  const size = result.width && result.height ? ` ${result.width}×${result.height}` : "";
  console.log(`Captured ${kind.replace("-", " ")} on ${host}${size}`);
  console.log(`  saved: ${path}`);
  if (copied !== undefined) console.log(`  clipboard: ${copied ? "copied" : "not copied"}`);
}

/** Parse `lats capture display` without the loose shared positional parser. */
export function parseCaptureDisplayArgs(args: string[]): CaptureDisplayArgs {
  const flags = new Map<string, string | true>();
  const positional: string[] = [];
  const booleanFlags = new Set(["clipboard", "json"]);
  const valueFlags = new Set(["delay", "filename", "out", "run-id", "runId"]);

  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (!argument.startsWith("--")) {
      positional.push(argument);
      continue;
    }

    const match = argument.match(/^--([^=]+)(?:=(.*))?$/u);
    if (!match) throw new Error(`Unknown option: ${argument}`);
    const name = match[1]!;
    const inlineValue = match[2];

    if (booleanFlags.has(name)) {
      if (inlineValue !== undefined) {
        throw new Error(`--${name} does not take a value`);
      }
      flags.set(name, true);
      continue;
    }

    if (!valueFlags.has(name)) {
      throw new Error(`Unknown option: --${name}`);
    }
    const value = inlineValue === undefined ? args[++index] : inlineValue;
    if (value === undefined || value === "" || value.startsWith("--")) {
      throw new Error(`--${name} expects a value`);
    }
    flags.set(name, value);
  }

  if (positional.length > 1) {
    throw new Error(`Unexpected argument: ${positional[1]}`);
  }

  let display: number | undefined;
  const rawDisplay = positional[0];
  if (rawDisplay !== undefined) {
    if (!/^\d+$/u.test(rawDisplay)) {
      throw new Error(`Display index must be a non-negative integer: ${rawDisplay}`);
    }
    display = Number(rawDisplay);
    if (!Number.isSafeInteger(display)) {
      throw new Error(`Display index must be a non-negative integer: ${rawDisplay}`);
    }
  }

  let delaySeconds = 0;
  const rawDelay = flags.get("delay");
  if (typeof rawDelay === "string") {
    if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/u.test(rawDelay)) {
      throw new Error(`--delay expects a non-negative number of seconds`);
    }
    delaySeconds = Number(rawDelay);
    if (!Number.isFinite(delaySeconds)) {
      throw new Error(`--delay expects a non-negative number of seconds`);
    }
  }

  const filename = flags.get("filename");
  const out = flags.get("out");
  const runId = flags.get("run-id") ?? flags.get("runId");
  return {
    display,
    clipboard: flags.get("clipboard") === true,
    delaySeconds,
    filename: typeof filename === "string" ? filename : undefined,
    runId: typeof runId === "string" ? runId : undefined,
    json: flags.get("json") === true,
    ...(typeof out === "string" ? { out } : {}),
  };
}

export function captureUsage(): string {
  return `lats capture — capture run artifacts

Usage:
  lats capture window [wid] [--json]
  lats capture screenshot [wid] [--session name] [--app name]
  lats capture display [index] [--clipboard] [--delay seconds] [--filename name] [--run-id id] [--json]
  lats --host <name> capture display [index] [--out path]   saved on this Mac, ~/.lattices/captures/<name>/
  lats --host <name> capture window [wid] [--app name] [--out path]
  lats capture record window [wid] [--app name] [--duration-ms 5000] [--json]
  lats capture record region --x N --y N --width N --height N [--duration-ms 5000]
  lats capture record-command --app Scout --filename demo.mov -- <command> [...args]
  lats capture stop <run-id>
  lats capture log [--limit 20] [--json]   screenshots agents took (~/.lattices/audit)`;
}

export async function captureCommand(subcommand?: string, ...rawArgs: string[]): Promise<void> {
  const sub = subcommand || "window";
  const dashIndex = rawArgs.indexOf("--");
  const commandArgs = dashIndex >= 0 ? rawArgs.slice(0, dashIndex) : rawArgs;
  const childArgs = dashIndex >= 0 ? rawArgs.slice(dashIndex + 1) : [];
  const jsonFlag = hasFlag(commandArgs, "json");
  const positional = nonFlagArgs(commandArgs);

  if (sub === "log" || sub === "audit") {
    captureLog(commandArgs);
    return;
  }

  if (["stop", "stop-recording", "stopRecording"].includes(sub)) {
    const params: Record<string, unknown> = {};
    const runId = positional[0] || parseFlagValue(commandArgs, "run-id") || parseFlagValue(commandArgs, "runId") || parseFlagValue(commandArgs, "id");
    const stopFile = parseFlagValue(commandArgs, "stop-file") || parseFlagValue(commandArgs, "stopFile");
    const finishedFile = parseFlagValue(commandArgs, "finished-file") || parseFlagValue(commandArgs, "finishedFile");
    const timeoutMs = Number(parseFlagValue(commandArgs, "timeout-ms") || parseFlagValue(commandArgs, "timeoutMs") || 30000);
    if (runId) params.runId = runId;
    if (stopFile) params.stopFile = stopFile;
    if (finishedFile) params.finishedFile = finishedFile;
    if (Number.isFinite(timeoutMs)) params.timeoutMs = timeoutMs;
    params.wait = !hasFlag(commandArgs, "no-wait");

    await withDaemon(async ({ daemonCall }) => {
      const result = await daemonCall("capture.stopRecording", params, timeoutMs + 5000) as any;
      if (jsonFlag) {
        console.log(JSON.stringify(result, null, 2));
        return;
      }
      console.log(result.finished ? "Recording finished." : "Recording stop requested.");
      if (result.run?.id) console.log(`  run: ${result.run.id}`);
      if (result.marker) console.log(`  marker: ${result.marker}`);
    });
    return;
  }

  const isRecordCommand = [
    "record-command",
    "recordCommand",
    "record-run",
    "recordRun",
    "record-exec",
    "recordExec",
  ].includes(sub);

  if (isRecordCommand) {
    if (!childArgs.length) {
      console.log(`lats capture record-command — record while running a command

Usage:
  lats capture record-command --app Scout --filename demo.mov -- <command> [...args]
`);
      return;
    }

    const params: Record<string, unknown> = { source: "cli" };
    const explicitWid = positional[0] ? Number(positional[0]) : NaN;
    if (Number.isFinite(explicitWid)) params.wid = explicitWid;

    const session = parseFlagValue(commandArgs, "session");
    const app = parseFlagValue(commandArgs, "app");
    const title = parseFlagValue(commandArgs, "title");
    const filename = parseFlagValue(commandArgs, "filename");
    const runId = parseFlagValue(commandArgs, "run-id") || parseFlagValue(commandArgs, "runId");
    const mode = parseFlagValue(commandArgs, "mode");
    const fps = parseOptionalNumber(commandArgs, "fps");
    const scale = parseOptionalNumber(commandArgs, "scale");
    const timeoutMs = Number(parseFlagValue(commandArgs, "timeout-ms") || parseFlagValue(commandArgs, "timeoutMs") || 30000);
    if (session) params.session = session;
    if (app) params.app = app;
    if (title) params.title = title;
    if (filename) params.filename = filename;
    if (runId) params.runId = runId;
    if (mode) params.mode = mode;
    if (fps !== undefined) params.fps = fps;
    if (scale !== undefined) params.scale = scale;

    for (const [flag, key] of [["x", "x"], ["y", "y"], ["width", "width"], ["height", "height"], ["w", "w"], ["h", "h"]] as const) {
      const value = parseOptionalNumber(commandArgs, flag);
      if (value !== undefined) params[key] = value;
    }

    const recordsRegion = hasFlag(commandArgs, "region") ||
      (params.x !== undefined && params.y !== undefined &&
        (params.width !== undefined || params.w !== undefined) &&
        (params.height !== undefined || params.h !== undefined));
    const method = recordsRegion ? "capture.recordRegion" : "capture.recordWindow";

    await withDaemon(async ({ daemonCall }) => {
      const start = await daemonCall(method, params, 20000) as any;
      let childExitCode = 0;
      let childError: string | undefined;

      try {
        const proc = Bun.spawn(childArgs, {
          cwd: process.cwd(),
          env: process.env,
          stdin: "inherit",
          stdout: "inherit",
          stderr: "inherit",
        });
        childExitCode = await proc.exited;
      } catch (error) {
        childExitCode = 127;
        childError = (error as Error).message;
      }

      const stop = await daemonCall(
        "capture.stopRecording",
        { runId: start.run?.id, wait: true, timeoutMs },
        timeoutMs + 5000
      ) as any;

      if (jsonFlag) {
        console.log(JSON.stringify({
          ok: childExitCode === 0 && stop.ok !== false,
          child: {
            command: childArgs,
            exitCode: childExitCode,
            error: childError,
          },
          recording: start,
          stopResult: stop,
        }, null, 2));
      } else {
        const artifact = start.artifact || {};
        const run = stop.run || start.run || {};
        console.log(`Recording finished.`);
        console.log(`  run: ${run.id || start.run?.id || "?"}`);
        console.log(`  artifact: ${artifact.path || "?"}`);
        console.log(`  child exit: ${childExitCode}`);
        if (childError) console.log(`  child error: ${childError}`);
      }

      if (childExitCode !== 0 && !hasFlag(commandArgs, "ignore-child-failure")) {
        process.exitCode = childExitCode;
      }
    });
    return;
  }

  const isRecord = ["record", "record-window", "recording", "video"].includes(sub);
  const isRecordRegion = ["record-region", "recordRegion", "region-recording"].includes(sub) ||
    (sub === "record" && ["region", "rect"].includes(positional[0] || ""));

  if (isRecord || isRecordRegion) {
    const params: Record<string, unknown> = { source: "cli" };
    const targetKind = sub === "record" ? positional[0] : undefined;
    const positionalOffset = targetKind === "window" || targetKind === "region" || targetKind === "rect" ? 1 : 0;
    const explicitWid = positional[positionalOffset] ? Number(positional[positionalOffset]) : NaN;
    if (Number.isFinite(explicitWid)) params.wid = explicitWid;

    const session = parseFlagValue(commandArgs, "session");
    const app = parseFlagValue(commandArgs, "app");
    const title = parseFlagValue(commandArgs, "title");
    const filename = parseFlagValue(commandArgs, "filename");
    const runId = parseFlagValue(commandArgs, "run-id") || parseFlagValue(commandArgs, "runId");
    const mode = parseFlagValue(commandArgs, "mode");
    const fps = parseOptionalNumber(commandArgs, "fps");
    const scale = parseOptionalNumber(commandArgs, "scale");
    const durationMs = parseOptionalNumber(commandArgs, "duration-ms", "durationMs", "duration");
    if (session) params.session = session;
    if (app) params.app = app;
    if (title) params.title = title;
    if (filename) params.filename = filename;
    if (runId) params.runId = runId;
    if (mode) params.mode = mode;
    if (fps !== undefined) params.fps = fps;
    if (scale !== undefined) params.scale = scale;

    for (const [flag, key] of [["x", "x"], ["y", "y"], ["width", "width"], ["height", "height"], ["w", "w"], ["h", "h"]] as const) {
      const value = parseOptionalNumber(commandArgs, flag);
      if (value !== undefined) params[key] = value;
    }

    await withDaemon(async ({ daemonCall }) => {
      const method = isRecordRegion ? "capture.recordRegion" : "capture.recordWindow";
      const result = await daemonCall(method, params, 20000) as any;

      if (durationMs !== undefined && durationMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, durationMs));
        const stop = await daemonCall(
          "capture.stopRecording",
          { runId: result.run?.id, wait: true, timeoutMs: 30000 },
          35000
        ) as any;
        result.stopResult = stop;
      }

      if (jsonFlag) {
        console.log(JSON.stringify(result, null, 2));
        return;
      }
      const artifact = result.artifact || {};
      const run = result.stopResult?.run || result.run || {};
      console.log(`Recording ${result.stopResult ? "finished" : "started"}.`);
      console.log(`  run: ${run.id || result.run?.id || "?"}`);
      console.log(`  artifact: ${artifact.path || "?"}`);
      if (!result.stopResult) {
        console.log(`  stop: lats capture stop ${result.run?.id || ""}`);
      }
    });
    return;
  }

  if (sub === "display") {
    const options = parseCaptureDisplayArgs(commandArgs);
    const params: Record<string, unknown> = {
      source: "cli",
      clipboard: options.clipboard,
    };
    if (options.display !== undefined) params.display = options.display;
    if (options.filename) params.filename = options.filename;
    if (options.runId) params.runId = options.runId;

    const host = remoteHostName();
    if (host) {
      // The Linux host reads `displayIndex`; `inline` brings the image back.
      if (options.display !== undefined) params.displayIndex = options.display;
      params.inline = true;
      params.clipboard = false;
    }

    await withDaemon(async ({ daemonCall }) => {
      if (options.delaySeconds > 0) {
        await new Promise((resolve) => setTimeout(resolve, options.delaySeconds * 1000));
      }

      const result = await daemonCall("capture.screenshotDisplay", params, 20000) as any;
      if (host) {
        const kind = `display-${result.displayIndex ?? options.display ?? 0}`;
        await saveRemoteCapture(host, kind, result, options);
        return;
      }
      if (options.json) {
        console.log(JSON.stringify(result, null, 2));
        return;
      }

      const artifact = result.artifact || {};
      const run = result.run || {};
      const display = result.display || {};
      const displayIndex = display.displayIndex ?? options.display;
      const displayLabel = display.name
        ? `${display.name}${displayIndex !== undefined ? ` (display ${displayIndex})` : ""}`
        : (displayIndex !== undefined ? `Display ${displayIndex}` : "display");
      console.log(`Captured ${displayLabel}`);
      console.log(`  run: ${run.id || "?"}`);
      console.log(`  artifact: ${artifact.path || "?"}`);
      if (options.clipboard) {
        console.log(`  clipboard: ${result.clipboard?.copied === true ? "copied" : "not copied"}`);
      }
    });
    return;
  }

  if (!["window", "screenshot", "shot"].includes(sub)) {
    console.log(captureUsage());
    return;
  }

  const params: Record<string, unknown> = { source: "cli" };
  const explicitWid = positional[0] ? Number(positional[0]) : NaN;
  if (Number.isFinite(explicitWid)) params.wid = explicitWid;
  const session = parseFlagValue(commandArgs, "session");
  const app = parseFlagValue(commandArgs, "app");
  const title = parseFlagValue(commandArgs, "title");
  const filename = parseFlagValue(commandArgs, "filename");
  const runId = parseFlagValue(commandArgs, "run-id") || parseFlagValue(commandArgs, "runId");
  if (session) params.session = session;
  if (app) params.app = app;
  if (title) params.title = title;
  if (filename) params.filename = filename;
  if (runId) params.runId = runId;
  const host = remoteHostName();
  if (host) params.inline = true;

  await withDaemon(async ({ daemonCall }) => {
    const result = await daemonCall("capture.screenshotWindow", params, 20000) as any;
    if (host) {
      const out = parseFlagValue(commandArgs, "out");
      await saveRemoteCapture(host, `window-${result.wid ?? params.wid ?? "front"}`, result, {
        out: out || undefined, filename: filename || undefined, clipboard: hasFlag(commandArgs, "clipboard"), json: jsonFlag,
      });
      return;
    }
    if (jsonFlag) {
      console.log(JSON.stringify(result, null, 2));
      return;
    }
    const artifact = result.artifact || {};
    const run = result.run || {};
    const target = result.target || {};
    console.log(`Captured ${target.app || "window"} ${target.wid ? `wid:${target.wid}` : ""}`);
    console.log(`  run: ${run.id || "?"}`);
    console.log(`  artifact: ${artifact.path || "?"}`);
  });
}
