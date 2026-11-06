#!/usr/bin/env node
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { BackendHost, defaultAllowTiers, parseAllowTiers, parseBackendAction } from "./host.js";
import { askForBackend } from "./ask.js";
import { systemApp, type AppControl, type AppStatus } from "./app.js";
import { serveMcp } from "./mcp.js";
import { cuaError, cuaHandlers } from "./tools.js";
import {
  BackendRefusal,
  type BackendAxNode,
  type BackendAvailability,
  type BackendNeed,
  type BackendObservation,
  type BackendSetupResult,
  type BackendSetupStep,
  type BackendTarget,
} from "./types.js";

export const help = `Usage: action <command> [options]

Action.app:
  install [--launch]                       Install the latest Action.app into /Applications
  update [--launch]                        Same as install
  launch                                   Open Action.app
  quit                                     Quit Action.app
  call <method> [params-json]              Call the Action agent directly

Computer use:
  status [backend]                         Report Action.app, then backend readiness and tiers
  mcp                                      Serve MCP over stdin/stdout
  setup <backend|all>                      Request permissions and guide setup
  ask <backend>                            Ask for missing permissions in an Action panel
  targets <backend>                        List apps or windows
  observe <backend> <target>                Read the accessibility tree
  press <backend> <target> --label <regex>   Press a matching AX element
  set <backend> <target> --label <regex> --value <text>
                                           Set a matching element's value
  act <backend> <target> '<action json>'     Send a backend action

Options:
  --json                 Print JSON (mcp always speaks the MCP protocol)
  --config <path>        Set ACTION_BACKENDS_CONFIG
  --first                Select the first matching target
  --screenshot           Also capture a screenshot when observing
  --roles <regex>        Filter observed AX roles
  --label <regex>        Select an AX label from a fresh observation
  --role <AXRole>        Restrict label matches to this exact role
  --nth N                Select the Nth matching element (1-based)
  --value <text>         Value for set; an empty string is allowed
  --allow <tier,...>     Add tiers to observe,semantic (e.g. attention)
  --help, -h             Show this help

Targets match a targetId (its generation prefix optional), a bundle ID exactly,
or app/window names by case-insensitive
regex. Ambiguous matches fail unless --first is supplied. Labels and --roles
also use case-insensitive regex sources; use ^ and $ for exact matches.

Every action lists targets and observes in the same process before acting.
Refs from another invocation cannot be reused. For ref-based action JSON,
omit ref and use --label, --role and --nth to resolve it in this invocation.
Point actions capture a fresh screenshot automatically. Success means
delivered_unverified; observe again to check the effect.

Setup may show macOS permission dialogs or open System Settings, and waits up
to about two minutes per backend. In a terminal, commands offer setup when a
backend needs permissions. Non-interactive commands print the fix and fail.

A label of ^$ selects elements that have no label.

Other commands (layer, capabilities, …) run in an Action runtime checkout when
one is found: ACTION_ROOT, the managed Lattices runtime, or this repository.

Examples:
  action install --launch
  action status --json
  action setup action-cua
  action call capture.screenshotScreen '{"output":"/tmp/action.png"}'
  action observe codex-cua com.google.Chrome --roles 'AXRadioButton|AXButton'
  action press codex-cua com.google.Chrome --label '^Project notes$' --role AXRadioButton
  action act trycua-cua Chrome '{"kind":"key","combo":"cmd+l"}' --allow attention
  action act trycua-cua Chrome '{"kind":"press"}' --label '^Save$'
`;

const invalid = (message: string) => new BackendRefusal("invalid-action", message);

function pattern(source: string, name: string): RegExp {
  if (!source.trim()) throw invalid(`${name} must not be empty.`);
  try {
    return new RegExp(source, "i");
  } catch (error) {
    throw invalid(`Invalid ${name} regex ${JSON.stringify(source)}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function targetLine(target: BackendTarget): string {
  return [target.app, target.title, target.bundleId, target.targetId].filter(Boolean).join(" | ");
}

/** Select by identity first (a window's bundle:pid:windowNumber, or a bundle ID), then a case-insensitive app/window regex. Never match positional IDs. */
export function selectTarget(targets: BackendTarget[], selector: string, opts: { first?: boolean } = {}): BackendTarget {
  if (!selector.trim()) throw invalid("target must not be empty.");
  // A window identity (bundle:pid:windowNumber) is stable across runs, so a window targetId
  // from an earlier run, or one without its generation, still selects it. Positional IDs never do.
  const windowId = /^(?:[0-9a-f]{8}:)?([^:\s]+:\d+:\d+)$/.exec(selector.trim())?.[1];
  const byId = windowId ? targets.filter((target) => target.targetId.replace(/^[0-9a-f]{8}:/, "") === windowId) : [];
  const exact = byId.length ? byId : targets.filter((target) => target.bundleId === selector);
  const regex = exact.length ? undefined : pattern(selector, "target");
  const matches = exact.length ? exact : targets.filter((target) => regex!.test(target.app) || regex!.test(target.title ?? ""));
  if (matches.length === 1 || (opts.first && matches.length > 0)) return matches[0]!;
  const candidates = matches.length ? matches : targets;
  throw new BackendRefusal("unknown-target", `${matches.length ? `${matches.length} targets match` : "No targets match"} ${JSON.stringify(selector)}. ${matches.length ? "Narrow the selector or use --first. " : ""}Candidates:\n${candidates.length ? candidates.map((target) => `  ${targetLine(target)}`).join("\n") : "  (none)"}`);
}

/** Select a node from this invocation's observation; nth is deliberately 1-based. */
export function selectNode(nodes: BackendAxNode[], label: string, opts: { role?: string; nth?: number } = {}): BackendAxNode {
  const regex = pattern(label, "label");
  if (opts.nth !== undefined && (!Number.isSafeInteger(opts.nth) || opts.nth < 1)) throw invalid("--nth must be a positive integer (1-based).");
  const eligible = nodes.filter((node) => opts.role === undefined || node.role === opts.role);
  // An unlabelled element matches as "", so ^$ can reach it.
  const matches = eligible.filter((node) => regex.test(node.label ?? ""));
  if (opts.nth !== undefined && matches[opts.nth - 1]) return matches[opts.nth - 1]!;
  if (opts.nth === undefined && matches.length === 1) return matches[0]!;
  const candidates = matches.length ? matches : eligible;
  const reason = opts.nth !== undefined ? `--nth ${opts.nth} is outside the ${matches.length} matching elements` : `${matches.length} elements match label ${JSON.stringify(label)}`;
  throw invalid(`${reason}${opts.role ? ` with role ${opts.role}` : ""}. Narrow --label/--role or choose --nth. Candidates:\n${candidates.length ? candidates.map((node, index) => `  ${index + 1}. ${node.role} ${JSON.stringify(node.label ?? "")} (${node.ref})`).join("\n") : "  (none)"}`);
}

type ParsedArgs = { positionals: string[]; flags: Map<string, string | true> };
const BOOLEAN_FLAGS = new Set(["json", "help", "first", "screenshot", "launch"]);
const VALUE_FLAGS = new Set(["config", "roles", "label", "role", "nth", "value", "allow"]);

function parseArgs(argv: string[]): ParsedArgs {
  const positionals: string[] = [];
  const flags = new Map<string, string | true>();
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    if (arg === "--") {
      positionals.push(...argv.slice(i + 1));
      break;
    }
    if (arg === "-h") { flags.set("help", true); continue; }
    if (!arg.startsWith("-")) { positionals.push(arg); continue; }
    if (!arg.startsWith("--")) throw invalid(`Unknown option ${arg}. Use --help.`);
    const equals = arg.indexOf("=");
    const name = arg.slice(2, equals < 0 ? undefined : equals);
    if (flags.has(name)) throw invalid(`--${name} may only be supplied once.`);
    if (BOOLEAN_FLAGS.has(name)) {
      if (equals >= 0) throw invalid(`--${name} does not take a value.`);
      flags.set(name, true);
    } else if (VALUE_FLAGS.has(name)) {
      const value = equals >= 0 ? arg.slice(equals + 1) : argv[++i];
      if (value === undefined || (equals < 0 && value.startsWith("--"))) throw invalid(`--${name} needs a value.`);
      flags.set(name, value);
    } else {
      throw invalid(`Unknown option --${name}. Use --help.`);
    }
  }
  return { positionals, flags };
}

function stringFlag(flags: ParsedArgs["flags"], name: string): string | undefined {
  const value = flags.get(name);
  return typeof value === "string" ? value : undefined;
}

function requestedCommand(argv: string[]): string | undefined {
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    if (arg === "--") return argv[i + 1];
    if (!arg.startsWith("-")) return arg;
    if (arg.startsWith("--") && !arg.includes("=") && VALUE_FLAGS.has(arg.slice(2))) i += 1;
  }
  return undefined;
}

function requiredFlag(flags: ParsedArgs["flags"], name: string, allowEmpty = false): string {
  const value = stringFlag(flags, name);
  if (value === undefined || (!allowEmpty && !value.trim())) throw invalid(`--${name} is required.`);
  return value;
}

const commandFlags: Record<string, string[]> = {
  install: ["launch"], update: ["launch"], launch: [], quit: [], call: [],
  mcp: [], status: [], setup: [], ask: [], targets: [],
  observe: ["first", "screenshot", "roles"],
  press: ["first", "label", "role", "nth", "allow"],
  set: ["first", "label", "role", "nth", "value", "allow"],
  act: ["first", "label", "role", "nth", "allow", "screenshot"],
};

function validateArgs({ positionals, flags }: ParsedArgs): string {
  const command = positionals[0]!;
  if (!Object.hasOwn(commandFlags, command)) throw invalid(`Unknown command ${JSON.stringify(command)}. Use --help.`);
  const length = positionals.length;
  const expected = ["mcp", "install", "update", "launch", "quit"].includes(command) ? [1] : command === "status" ? [1, 2] : command === "call" ? [2, 3] : command === "targets" || command === "setup" || command === "ask" ? [2] : command === "act" ? [4] : [3];
  if (!expected.includes(length)) throw invalid(`Invalid arguments for ${command}. Use --help for its syntax.`);
  for (const name of flags.keys()) {
    if (!["json", "config", "help", ...commandFlags[command]!].includes(name)) throw invalid(`--${name} does not apply to ${command}.`);
  }
  if ((flags.has("role") || flags.has("nth")) && !flags.has("label")) throw invalid("--role and --nth require --label.");
  return command;
}

function bodyOf(reply: CallToolResult): Record<string, unknown> {
  if (reply.structuredContent) return reply.structuredContent;
  const item = reply.content.find((content) => content.type === "text");
  return item?.type === "text" ? JSON.parse(item.text) as Record<string, unknown> : {};
}

function observationLines(observation: BackendObservation): string[] {
  const lines = [`Observation ${observation.observationId} (${observation.targetId})`];
  if (observation.screenshot) lines.push(`Screenshot: ${observation.screenshot.path}`);
  for (const node of observation.ax ?? []) {
    lines.push(`${"  ".repeat(Math.max(0, Math.min(node.depth, 20)))}${node.ref} ${node.role}${node.label !== undefined ? ` ${JSON.stringify(node.label)}` : ""}${node.value !== undefined ? ` = ${JSON.stringify(node.value)}` : ""}${node.actions?.length ? ` [${node.actions.join(", ")}]` : ""}`);
  }
  if (!observation.ax?.length) lines.push("(no matching accessibility elements)");
  return lines;
}

function needLines(needs: BackendNeed[] | undefined): string[] {
  return (needs ?? []).flatMap((need) => [
    `  Needs ${need.permission ?? need.kind}${need.app ? ` (${need.app})` : ""}: ${need.detail}`,
    `  Fix: ${need.fix}`,
  ]);
}

function stepLine(step: BackendSetupStep): string {
  return `[${step.status}] ${step.step}${step.detail ? `: ${step.detail}` : ""}`;
}

function backendLines(backend: Record<string, unknown>): string[] {
  return [
    `${backend.backend}: ${backend.ready ? "ready" : "not ready"}${backend.version ? ` (${backend.version})` : ""}`,
    ...(backend.reason ? [`  ${backend.reason}`] : []),
    ...(Array.isArray(backend.steps) ? (backend.steps as BackendSetupStep[]).map((step) => `  ${stepLine(step)}`) : []),
    ...needLines(backend.needs as BackendNeed[] | undefined),
    ...(backend.tiers ? [`  Tiers: ${Object.entries(backend.tiers as Record<string, string>).map(([kind, tier]) => `${kind}=${tier}`).join(", ")}`] : []),
  ];
}

function appLines(app: AppStatus): string[] {
  return [
    `Action.app: ${app.installed ? `${app.version ?? "unknown version"} (${app.path})` : "not installed; run action install"}`,
    `  ${app.running ? "running" : "not running"}; agent ${app.agentReachable ? "reachable" : "not reachable"}`,
  ];
}

function readable(body: Record<string, unknown>, isError: boolean): string {
  if (Array.isArray(body.backends)) {
    const backends = (body.backends as Array<Record<string, unknown>>).map((backend) => backendLines(backend).join("\n")).join("\n") || "No backends registered.";
    return body.app ? [...appLines(body.app as AppStatus), backends].join("\n") : backends;
  }
  if (Array.isArray(body.steps)) return backendLines(body).join("\n");
  if (isError) {
    const delivery = body.delivery as { status?: string } | string | undefined;
    const status = typeof delivery === "string" ? delivery : delivery?.status;
    return [
      `${body.code ?? "error"}: ${body.message ?? "Command failed"}`,
      ...needLines(body.needs as BackendNeed[] | undefined),
      ...(status ? [`Delivery: ${status}`] : []),
      ...(body.observation ? observationLines(body.observation as BackendObservation) : []),
    ].join("\n");
  }
  if (Array.isArray(body.targets)) return (body.targets as BackendTarget[]).map(targetLine).join("\n") || "No targets found.";
  if (body.result) {
    const result = body.result as Record<string, unknown>;
    const delivery = (result.delivery ?? body.delivery) as { status?: string } | undefined;
    const lines = [`${body.backend}: ${delivery?.status ?? "delivered_unverified"}`, `Tier: ${result.tierUsed}; mechanism: ${result.mechanism}`];
    if (result.tierExceeded) lines.push("The backend reported a tier outside allowTiers.");
    if (result.message) lines.push(String(result.message));
    if (body.observation) lines.push(...observationLines(body.observation as BackendObservation));
    return lines.join("\n");
  }
  if (body.observation) return observationLines(body.observation as BackendObservation).join("\n");
  if (body.ok === true && typeof body.message === "string") return body.message;
  return JSON.stringify(body, null, 2);
}

export type CliOptions = {
  host?: BackendHost;
  /** Action.app lifecycle; tests replace the machine. */
  app?: AppControl;
  stdout?: (text: string) => void;
  stderr?: (text: string) => void;
  /** Test seams: stdout's terminal state and the operator's answer. */
  isTTY?: boolean;
  prompt?: (question: string) => Promise<string>;
};

/** Runs one command and disposes its host. Injectable output and host keep tests off the screen. */
export async function runCli(argv: string[], options: CliOptions = {}): Promise<number> {
  const stdout = options.stdout ?? ((text: string) => { process.stdout.write(text); });
  const stderr = options.stderr ?? ((text: string) => { process.stderr.write(text); });
  let json = argv.includes("--json");
  const mcpRequested = requestedCommand(argv) === "mcp";
  let host = options.host;
  let serving = false;
  const cancellation = new AbortController();
  let cancelledBy: "SIGINT" | "SIGTERM" | undefined;
  const cancel = (signal: "SIGINT" | "SIGTERM") => {
    cancelledBy ??= signal;
    cancellation.abort(new Error(`Command cancelled by ${signal}.`));
  };
  const onInterrupt = () => cancel("SIGINT");
  const onTerminate = () => cancel("SIGTERM");
  const callInput = { signal: cancellation.signal, caller: "cli" };
  const emit = (body: Record<string, unknown>, isError = false): number => {
    const machineOutput = json && !(mcpRequested && isError);
    (machineOutput || !isError ? stdout : stderr)(`${machineOutput ? JSON.stringify(body, null, 2) : readable(body, isError)}\n`);
    return cancelledBy === "SIGINT" ? 130 : cancelledBy === "SIGTERM" ? 143 : isError ? 1 : 0;
  };
  const app = options.app ?? systemApp;
  try {
    // Commands this package does not own go to a runtime checkout, flags untouched.
    const requested = requestedCommand(argv);
    if (requested !== undefined && !Object.hasOwn(commandFlags, requested)) {
      const status = app.forward(argv);
      if (status !== undefined) return status;
      throw invalid(`Unknown command ${JSON.stringify(requested)}. Use --help. (No Action runtime checkout was found to forward it to; set ACTION_ROOT.)`);
    }
    const parsed = parseArgs(argv);
    const { positionals, flags } = parsed;
    json = flags.has("json");
    if (flags.has("help") || !positionals.length) {
      if (json) emit({ usage: help });
      else stdout(help);
      return 0;
    }
    const command = validateArgs(parsed);
    if (command === "install" || command === "update") {
      const result = await app.install((line) => stderr(`${line}\n`));
      const launched = flags.has("launch") ? app.launch() : undefined;
      const message = `${result.changed ? `Installed Action ${result.version} at ${result.path}.` : `Action ${result.version} is already installed at ${result.path}.`}${launched ? ` ${launched.wasRunning ? "Focused" : "Launched"} it.` : ""}${result.changed ? " Then run: action setup action-cua" : ""}`;
      return emit({ ok: true, ...result, ...(launched ? { launched: true } : {}), message });
    }
    if (command === "launch") {
      const launched = app.launch();
      return emit({ ok: true, ...launched, message: launched.wasRunning ? "Action focused." : "Action launched." });
    }
    if (command === "quit") {
      const quit = await app.quit();
      return emit({ ok: quit, ...(quit ? { message: "Action quit. Prepared workspaces stay available." } : { code: "unavailable", message: "Could not confirm that Action quit." }) }, !quit);
    }
    if (command === "call") {
      let params: Record<string, unknown> | null = null;
      if (positionals[2] !== undefined) {
        try { params = JSON.parse(positionals[2]) as Record<string, unknown>; } catch { throw invalid("params must be valid JSON."); }
        if (!params || typeof params !== "object" || Array.isArray(params)) throw invalid("params must be a JSON object.");
      }
      let reply: Awaited<ReturnType<AppControl["call"]>>;
      try { reply = await app.call(positionals[1]!, params, 30_000); }
      catch (error) {
        throw new BackendRefusal("unavailable", `The Action agent is not reachable (${error instanceof Error ? error.message : String(error)}). Run: action launch`);
      }
      if (!reply.ok) return emit({ ok: false, code: "failed", message: reply.error ?? "The Action agent call failed.", ...(reply.result ? { result: reply.result } : {}) }, true);
      // Print the agent's reply as is; it is already the useful body.
      stdout(`${JSON.stringify(reply.result ?? {}, null, 2)}\n`);
      return 0;
    }
    const config = stringFlag(flags, "config");
    if (config !== undefined) {
      if (!config.trim()) throw invalid("--config must not be empty.");
      process.env.ACTION_BACKENDS_CONFIG = resolve(config === "~" ? homedir() : config.startsWith("~/") ? join(homedir(), config.slice(2)) : config);
    }
    host ??= new BackendHost({ log: (...args) => stderr(`[action backend] ${args.map(String).join(" ")}\n`) });
    if (command === "mcp") {
      // stdout belongs entirely to the protocol, including when startup fails.
      json = false;
      serving = true;
      await serveMcp({ host });
      return 0;
    }
    // Keep the process alive until the backend has killed any in-flight grant
    // child and disposed its driver. MCP owns its own shutdown listeners.
    process.on("SIGINT", onInterrupt);
    process.on("SIGTERM", onTerminate);
    const handlers = cuaHandlers(host);
    const backend = positionals[1];
    const setup = async (id: string): Promise<BackendSetupResult> => {
      cancellation.signal.throwIfAborted();
      stderr(`${id}: setup may show permission dialogs or open System Settings; waiting up to about two minutes.\n`);
      return await host!.setup(id, {
        ...callInput,
        onSetupStep: (step) => stderr(`${id}: ${stepLine(step)}\n`),
      }, { interactive: true });
    };
    const ensureReady = async (id: string): Promise<Record<string, unknown> | undefined> => {
      cancellation.signal.throwIfAborted();
      const availability = await host!.availability(id, callInput);
      cancellation.signal.throwIfAborted();
      if (availability.ready) return;
      const unavailable = (status: BackendAvailability) => ({
        ok: false, backend: id, code: "unavailable",
        message: status.reason ?? `${id} is not ready.`,
        ...(status.needs?.length ? { needs: status.needs } : {}),
        delivery: { status: "not_delivered" },
      });
      const permissionNeeds = availability.needs?.length && availability.needs.every((need) => need.kind === "permission");
      if (!(options.isTTY ?? process.stdout.isTTY) || !permissionNeeds) return unavailable(availability);
      stderr(`${id}: ${availability.reason ?? "Permissions are required."}\n${needLines(availability.needs).join("\n")}\n`);
      const question = "Run setup now? [Y/n] ";
      let answer: string;
      if (options.prompt) answer = await options.prompt(question);
      else {
        const input = createInterface({ input: process.stdin, output: process.stderr });
        input.on("SIGINT", onInterrupt);
        try { answer = await input.question(question, { signal: cancellation.signal }); }
        catch { answer = "n"; }
        finally { input.close(); }
      }
      cancellation.signal.throwIfAborted();
      if (!/^(?:y|yes)?$/i.test(answer.trim())) return unavailable(availability);
      const result = await setup(id);
      cancellation.signal.throwIfAborted();
      if (result.ready) return;
      return { ...unavailable({ ready: false, reason: `${id} setup is incomplete.`, needs: result.needs }), ...result };
    };
    if (command === "status") {
      const [reply, appStatus] = await Promise.all([
        handlers.cua_status!({ ...(backend ? { backend } : {}) }, callInput),
        backend ? undefined : app.status(),
      ]);
      cancellation.signal.throwIfAborted();
      return emit({ ...(appStatus ? { app: appStatus } : {}), ...bodyOf(reply) }, reply.isError === true);
    }
    if (command === "setup") {
      const ids = backend === "all" ? host.ids() : [backend!];
      // Validate a named backend before printing setup instructions.
      if (backend !== "all") host.get(backend!);
      const results: Array<BackendSetupResult & { backend: string }> = [];
      for (const id of ids) {
        try { results.push({ backend: id, ...await setup(id) }); }
        catch (error) {
          results.push({ backend: id, ready: false, steps: [{
            step: "Setup", status: "failed", detail: error instanceof Error ? error.message : String(error),
          }] });
        }
        if (cancellation.signal.aborted) break;
      }
      const ready = !cancellation.signal.aborted && results.every((result) => result.ready);
      return emit(backend === "all" ? { ok: ready, backends: results } : { ok: ready, ...results[0]!, ready }, !ready);
    }
    if (command === "ask") {
      host.get(backend!);
      stderr(`${backend}: asking in an Action panel; it waits for the grants and closes itself.\n`);
      const result = await askForBackend(host, backend!, {
        signal: cancellation.signal, call: callInput, requester: { agent: callerName(), task: `Set up ${backend}` },
      });
      const ok = result.outcome === "satisfied" || result.outcome === "confirmed";
      return emit({ ok, backend, ...result }, !ok);
    }
    if (command === "targets") {
      const unavailable = await ensureReady(backend!);
      if (unavailable) return emit(unavailable, true);
      cancellation.signal.throwIfAborted();
      const reply = await handlers.cua_targets!({ backend }, callInput);
      cancellation.signal.throwIfAborted();
      return emit(bodyOf(reply), reply.isError === true);
    }

    // Validate local selectors and input before starting a backend process.
    const label = stringFlag(flags, "label");
    if (command === "press" || command === "set") requiredFlag(flags, "label");
    if (label !== undefined) pattern(label, "label");
    const roles = stringFlag(flags, "roles");
    const rolesPattern = roles === undefined ? undefined : pattern(roles, "roles");
    const nthText = stringFlag(flags, "nth");
    const nth = nthText === undefined ? undefined : Number(nthText);
    if (nth !== undefined && (!/^\d+$/.test(nthText!) || !Number.isSafeInteger(nth) || nth < 1)) throw invalid("--nth must be a positive integer (1-based).");
    const allow = stringFlag(flags, "allow");
    const allowTiers = parseAllowTiers(allow === undefined ? undefined : [...defaultAllowTiers, ...allow.split(",").map((tier) => tier.trim())]);
    let action: Record<string, unknown> | undefined;
    if (command === "press") action = { kind: "press" };
    if (command === "set") action = { kind: "setValue", value: requiredFlag(flags, "value", true) };
    if (command === "act") {
      try { action = JSON.parse(positionals[3]!) as Record<string, unknown>; } catch { throw invalid("action must be valid JSON."); }
      if (!action || typeof action !== "object" || Array.isArray(action)) throw invalid("action must be a JSON object.");
      if (Object.hasOwn(action, "ref")) throw invalid("CLI refs cannot be reused across invocations. Omit ref from the action JSON and use --label (with optional --role/--nth) to resolve a fresh ref.");
      if (label !== undefined && !["press", "setValue", "secondary", "type", "scroll"].includes(String(action.kind))) throw invalid(`--label does not apply to ${String(action.kind)}.`);
      // Validate shape with a placeholder, replaced only by a ref from this invocation.
      parseBackendAction({ ...action, ...(label === undefined ? {} : { ref: "pending-observation" }) });
    }

    const unavailable = await ensureReady(backend!);
    if (unavailable) return emit(unavailable, true);
    cancellation.signal.throwIfAborted();
    const targets = await host.targets(backend!, callInput);
    cancellation.signal.throwIfAborted();
    const target = selectTarget(targets, positionals[2]!, { first: flags.has("first") });
    if (command === "observe") {
      const reply = await handlers.cua_observe!({ backend, targetId: target.targetId, screenshot: flags.has("screenshot") }, callInput);
      cancellation.signal.throwIfAborted();
      const body = bodyOf(reply);
      if (!reply.isError && rolesPattern && body.observation) {
        const observation = body.observation as BackendObservation;
        body.observation = { ...observation, ax: observation.ax?.filter((node) => rolesPattern.test(node.role)) };
      }
      return emit(body, reply.isError === true);
    }

    const needsScreenshot = flags.has("screenshot") || action?.kind === "click" || (action?.kind === "scroll" && action.point !== undefined && label === undefined);
    const observation = await host.observe(backend!, target.targetId, needsScreenshot, callInput);
    cancellation.signal.throwIfAborted();
    if (label !== undefined) {
      const node = selectNode(observation.ax ?? [], label, { role: stringFlag(flags, "role"), nth });
      action = { ...action, ref: node.ref };
    }
    const reply = await handlers.cua_act!({ backend, targetId: target.targetId, observationId: observation.observationId, action, allowTiers }, callInput);
    cancellation.signal.throwIfAborted();
    return emit(bodyOf(reply), reply.isError === true);
  } catch (error) {
    return emit(bodyOf(cuaError(error)), true);
  } finally {
    try { if (!serving) await host?.dispose(); }
    finally {
      process.off("SIGINT", onInterrupt);
      process.off("SIGTERM", onTerminate);
    }
  }
}

function isEntryPoint(): boolean {
  if (!process.argv[1]) return false;
  try { return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; }
}

if (isEntryPoint()) process.exitCode = await runCli(process.argv.slice(2));

/** Who is asking, as the operator would name it. The panel's eyebrow shows it. */
function callerName(): string {
  if (process.env.CLAUDECODE) return "Claude Code";
  if (Object.keys(process.env).some((key) => key.startsWith("CODEX_"))) return "Codex";
  return "Terminal";
}
