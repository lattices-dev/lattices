import { execSync } from "node:child_process";

export interface ExecOpts {
  encoding?: string;
  stdio?: string | string[];
  cwd?: string;
  [key: string]: any;
}

export function run(cmd: string, opts: ExecOpts = {}): string {
  return execSync(cmd, { encoding: "utf8", ...opts } as any).trim();
}

export function runQuiet(cmd: string): string | null {
  try {
    return run(cmd, { stdio: "pipe" });
  } catch {
    return null;
  }
}

export function parseFlagValue(args: string[], name: string): string | undefined {
  const prefix = `--${name}=`;
  const exact = `--${name}`;
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith(prefix)) return args[i].slice(prefix.length);
    if (args[i] === exact) return args[i + 1];
  }
  return undefined;
}

export function parseOptionalNumber(args: string[], ...names: string[]): number | undefined {
  for (const name of names) {
    const raw = parseFlagValue(args, name);
    if (raw === undefined || raw === "") continue;
    const value = Number(raw);
    if (Number.isFinite(value)) return value;
  }
  return undefined;
}

export function hasFlag(args: string[], name: string): boolean {
  return args.includes(`--${name}`);
}

export function nonFlagArgs(args: string[]): string[] {
  const valueFlags = new Set([
    "id", "state", "ttl", "ttlMs", "x", "y", "gap", "placement", "style", "name", "scale",
    "hud-url", "hudUrl", "hud-html", "hudHTML", "hudHtml", "hud-title", "hudTitle",
    "hud-width", "hudWidth", "hud-height", "hudHeight", "width", "height",
    "manifest", "root", "max-depth", "maxDepth", "read-access", "readAccess",
    "pause", "limit", "session", "app", "name", "bundle-id", "bundleId", "bundleIdentifier",
    "path", "app-path", "appPath", "title", "filename", "out", "run-id", "runId",
    "text", "tty", "wid", "treatment", "mode", "phase", "transport", "capture",
    "appearance", "cursor-style", "cursorStyle", "shape", "marker-shape", "markerShape",
    "cursor-shape", "cursorShape", "angle-deg", "angleDeg", "rotation-deg", "rotationDeg",
    "rotation", "angle", "color", "duration-ms", "durationMs",
    "type-interval-ms", "typeIntervalMs", "typing-interval-ms", "typingIntervalMs", "label",
    "caption", "treatment-label", "treatmentLabel", "variant",
    "caption-title", "captionTitle", "caption-body", "captionBody",
    "caption-detail", "captionDetail", "caption-tags", "captionTags",
    "caption-mode", "captionMode", "caption-eyebrow", "captionEyebrow",
    "caption-lead-ms", "captionLeadMs", "caption-sound", "captionSound",
    "caption-placement", "captionPlacement", "caption-margin", "captionMargin",
    "caption-x", "captionX", "caption-y", "captionY",
    "caption-x-ratio", "captionXRatio", "caption-y-ratio", "captionYRatio",
    "caption-left-ratio", "captionLeftRatio", "caption-top-ratio", "captionTopRatio",
    "sound", "sfx",
    "trail", "effect", "path-style", "pathStyle", "motion", "easing", "velocity",
    "trajectory", "curve", "arc", "glow", "bloom", "idle", "settle", "presence",
    "edge", "edge-effect", "edgeEffect", "arrival",
    "fps", "w", "h", "stop-file", "stopFile", "finished-file", "finishedFile",
    "timeout-ms", "timeoutMs", "duration",
    "x", "y", "x-ratio", "xRatio", "y-ratio", "yRatio",
    "relative-x", "relativeX", "relative-y", "relativeY",
    "window-x", "windowX", "window-y", "windowY", "button",
  ]);
  const out: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (!arg.startsWith("--")) {
      out.push(arg);
      continue;
    }
    const flagName = arg.slice(2);
    if (!arg.includes("=") && valueFlags.has(flagName)) i++;
  }
  return out;
}

export function relativeTime(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  const s = Math.floor(ms / 1000);
  if (s < 60) return "just now";
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  return `${d}d ago`;
}

export function pause(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}
