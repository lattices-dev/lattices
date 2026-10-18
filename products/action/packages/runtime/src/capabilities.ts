import { layerSafety } from "./layer-safety.js";
import { displayConfigurationDigest, layerAcceptance, type LayerAcceptanceBinding } from "./layer-acceptance.js";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative, resolve } from "node:path";

function jsonFile(path: string): Record<string, unknown> | null {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return null; }
}

/** Fingerprint the shipped orchestration, not the semver or a possibly absent .git. */
export function orchestrationDigest(root: string): string {
  const hash = createHash("sha256");
  const visit = (path: string) => {
    for (const entry of readdirSync(path, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
      const child = join(path, entry.name);
      if (entry.isDirectory()) visit(child);
      else if (entry.name.endsWith(".ts") || entry.name === "package.json") {
        hash.update(relative(root, child)); hash.update("\0"); hash.update(readFileSync(child)); hash.update("\0");
      }
    }
  };
  if (existsSync(join(root, "packages"))) visit(join(root, "packages"));
  hash.update(readFileSync(join(root, "package.json")));
  return hash.digest("hex");
}

function readActionAcceptance(input: {
  executable: string; executableSha256: string | null; nativeManifest: Record<string, unknown> | null;
  nativeHostPath: string; defaultHost: string; sourceDigest: string;
}, options: { path?: string; now?: number } = {}) {
  const { executable, executableSha256, nativeManifest, nativeHostPath, defaultHost, sourceDigest } = input;
  const nativeFeatures = nativeManifest?.features as Record<string, unknown> | undefined;
  const nativeBuild = nativeManifest?.build as Record<string, unknown> | undefined;
  const acceptanceBinding: Partial<LayerAcceptanceBinding> = {
    executableSha256: executableSha256 ?? undefined,
    nativeSourceDigest: typeof nativeBuild?.sourceDigest === "string" ? nativeBuild.sourceDigest : undefined,
    orchestrationSourceDigest: sourceDigest,
  };
  let acceptanceContextError: string | undefined;
  if (nativeHostPath !== defaultHost) {
    acceptanceContextError = "Custom native host provenance is unverified.";
  } else if (nativeFeatures?.isolationContext !== true || !executableSha256) {
    acceptanceContextError = "This installed bundle does not advertise read-only isolation-context discovery.";
  } else {
    try {
      const context = JSON.parse(execFileSync(executable, ["isolation-context"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 3000 }));
      if (context.schemaVersion !== 1 || typeof context.hostFingerprint !== "string" || !/^[a-f0-9]{64}$/.test(context.hostFingerprint)
        || typeof context.osBuild !== "string" || !context.osBuild.trim() || !Array.isArray(context.displayConfiguration) || !context.displayConfiguration.length) {
        throw new Error("Invalid native isolation context");
      }
      acceptanceBinding.hostFingerprint = context.hostFingerprint;
      acceptanceBinding.osBuild = context.osBuild;
      acceptanceBinding.displayConfigurationDigest = displayConfigurationDigest(context.displayConfiguration);
    } catch {
      acceptanceContextError = "Read-only native isolation-context discovery failed; current host/display binding is unavailable.";
    }
  }
  return { privateLayer: layerAcceptance(acceptanceBinding, { ...options, contextError: acceptanceContextError }) };
}

export function refreshActionCapabilities(capabilities: ReturnType<typeof actionCapabilities>, options: { path?: string; now?: number } = {}) {
  const executable = join(capabilities.native.bundlePath, "Contents/MacOS/Action");
  let executableSha256: string | null = null;
  try { executableSha256 = createHash("sha256").update(readFileSync(executable)).digest("hex"); } catch {}
  const nativeManifest = jsonFile(join(capabilities.native.bundlePath, "Contents/Resources/build-provenance.json"));
  const defaultHost = resolve(capabilities.orchestration.actionRoot, "native/engine/scripts/run-app-host.sh");
  const nativeHostPath = capabilities.native.nativeHostPath;
  const sourceDigest = capabilities.orchestration.sourceDigest;
  const nativeFeatures = nativeManifest?.features as Record<string, unknown> | undefined;
  const nativeBuild = nativeManifest?.build as Record<string, unknown> | undefined;
  const expectedOrchestrationDigest = nativeBuild?.orchestrationSourceDigest;
  const runtimeParity = nativeHostPath !== defaultHost || typeof expectedOrchestrationDigest !== "string"
    ? "unverified"
    : sourceDigest === expectedOrchestrationDigest ? "matched-source-digest" : "source-digest-mismatch";
  return {
    ...capabilities,
    runtimeParity: { ...capabilities.runtimeParity, state: runtimeParity, expectedOrchestrationDigest: expectedOrchestrationDigest ?? null },
    native: {
      ...capabilities.native, executableSha256, manifest: nativeManifest,
      privateLayer: nativeHostPath !== defaultHost ? "unverified-override" : nativeFeatures?.privateLayer === true ? "declared-by-build" : "unverified",
    },
    safety: { privateLayer: layerSafety() },
    acceptance: readActionAcceptance({ executable, executableSha256, nativeManifest, nativeHostPath, defaultHost, sourceDigest }, options),
  };
}

export function actionCapabilities(root: string, options: { nativeHostPath?: string; mcpTools?: string[]; sourceRoot?: string } = {}) {
  root = resolve(root);
  const sourceRoot = resolve(options.sourceRoot ?? root);
  const packageInfo = jsonFile(join(sourceRoot, "package.json"));
  let commit: string | null = null;
  let dirty: boolean | null = null;
  try {
    commit = execFileSync("git", ["-C", sourceRoot, "rev-parse", "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 2000 }).trim();
    dirty = execFileSync("git", ["-C", sourceRoot, "status", "--porcelain", "--", "."], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 2000 }).trim().length > 0;
  } catch { /* A deployed runtime does not need a git checkout. */ }
  const nativeHostPath = resolve(options.nativeHostPath ?? process.env.ACTION_NATIVE_HOST ?? join(root, "native/engine/scripts/run-app-host.sh"));
  const defaultHost = resolve(root, "native/engine/scripts/run-app-host.sh");
  const bundle = join(process.env.ACTION_DIST_DIR ?? join(root, "native/dist"), "Action.app");
  const nativeManifest = jsonFile(join(bundle, "Contents/Resources/build-provenance.json"));
  const executable = join(bundle, "Contents/MacOS/Action");
  const executableSha256 = existsSync(executable) ? createHash("sha256").update(readFileSync(executable)).digest("hex") : null;
  const nativeFeatures = nativeManifest?.features as Record<string, unknown> | undefined;
  const nativeBuild = nativeManifest?.build as Record<string, unknown> | undefined;
  const sourceDigest = orchestrationDigest(sourceRoot);
  const expectedOrchestrationDigest = nativeBuild?.orchestrationSourceDigest;
  const runtimeParity = nativeHostPath !== defaultHost || typeof expectedOrchestrationDigest !== "string"
    ? "unverified"
    : sourceDigest === expectedOrchestrationDigest ? "matched-source-digest" : "source-digest-mismatch";
  const requiredTools = ["layer_open", "layer_snapshot", "layer_click", "layer_type", "layer_js", "layer_close"];
  return {
    schemaVersion: 1,
    product: "Action",
    runtimeParity: { state: runtimeParity, expectedOrchestrationDigest: expectedOrchestrationDigest ?? null,
      note: "Compares this orchestration with the signed native build's recorded orchestration. Does not verify the running app or host desktop isolation." },
    safety: { privateLayer: layerSafety() },
    acceptance: readActionAcceptance({ executable, executableSha256, nativeManifest, nativeHostPath, defaultHost, sourceDigest }),
    orchestration: {
      version: packageInfo?.version ?? "unknown", actionRoot: root, sourceRoot, commit, dirty,
      sourceDigest, sourceScope: "packages/**/*.ts + package.json files",
      deployment: jsonFile(join(root, "runtime-provenance.json")),
    },
    native: {
      bundlePath: bundle, nativeHostPath, executableSha256, manifest: nativeManifest,
      privateLayer: nativeHostPath !== defaultHost ? "unverified-override" : nativeFeatures?.privateLayer === true ? "declared-by-build" : "unverified",
      runningProcessVerified: false,
    },
    transports: {
      mcp: {
        primary: true, launch: { command: "bun", args: [join(root, "packages/mcp/src/index.ts")], env: { ACTION_ROOT: root,
          ...(process.env.ACTION_DIST_DIR ? { ACTION_DIST_DIR: resolve(process.env.ACTION_DIST_DIR) } : {}),
          ...(nativeHostPath !== defaultHost ? { ACTION_NATIVE_HOST: nativeHostPath } : {}),
        } },
        requiredTools, advertisedTools: options.mcpTools ?? null,
        verification: options.mcpTools ? "this-server-tools-list" : "connect-and-list-tools",
        browser: { tool: "layer_open", arguments: { browser: true, pip: true } },
      },
      cli: { discovery: "lats action capabilities", commands: ["layer list", "layer prepare", "layer display-status", "layer open", "layer status", "layer snapshot", "layer pip", "layer record", "layer close", "layer release"], browserInteraction: "Use MCP layer_open with browser:true, then layer_click/type/js.", workspaceFlag: "--workspace", previewWorkspaceFlag: "--preview-workspace" },
      nativeHost: { discovery: "capabilities", role: "Native primitives; browser orchestration lives in MCP." },
      rawActionWebSocket: { privateLayerOrchestration: false, route: "Action MCP layer_* tools" },
      latticesDaemon: { privateLayerOrchestration: false, route: "Action MCP layer_* tools (not workspace layers)" },
    },
    notes: [
      "Named workspaces use independent persistent displays, browser identities, task ownership, and recordings. Pass workspace on every MCP layer call or --workspace on each CLI layer command; omission selects default, not the last workspace used.",
      "previewWorkspace embeds a layer preview on another prepared workspace. previewFull keeps the outer preview framed to its entire display. Recursive previews are refused. Native app input still shares macOS focus and is serialized; multiple displays do not provide independent keyboards.",
      "Open never replaces an active task. Close it explicitly before opening a replacement or releasing its display. Release refuses incoming previews without closing their tasks.",
      "Explicit layer prepare connects a stable persistent monitor. Task open/close only attach/detach and never hotplug it. First setup, owner restart and layer release change topology and are not task isolation guarantees.",
      "Check safety.privateLayer before opening: compiled layer support is not host isolation acceptance. A host quarantine blocks display creation.",
      "Check acceptance.privateLayer: accepted means a matching, unexpired operator evidence record, not running-process verification. Missing, invalid, stale or unverified evidence does not establish desktop preservation; quarantine remains independent.",
      "Version strings do not establish capability parity. Compare sourceDigest, native manifest and executableSha256; verify MCP tools/list on the active connection.",
      "runtimeParity reports a source digest mismatch or absent proof explicitly. A matching pair still requires host desktop-preservation acceptance; do not treat it as isolation proof.",
      "Reconnect or restart the harness MCP connection after updating its runtime/configuration. Existing connections may still serve old tools.",
      "Ordinary browser background:true is not private display isolation. Use layer_open {browser:true}.",
      "Discovery does not launch apps, build code, or verify permissions. Prove isolation with an observed layer browser interaction.",
    ],
  };
}
