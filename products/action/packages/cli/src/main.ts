#!/usr/bin/env bun

import { compileScenario } from "@action/compiler";
import {
  actionCapabilities,
  AgentLayerDirector,
  CompanionClient,
  inspectCurrentSurface,
  settleCurrentSurfaceViewport,
  StageDirector,
  StageSceneError,
} from "@action/runtime";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { runScenarioGuidedCaptureDemo } from "./index.js";
import { loadScenario } from "./scenarios.js";
import { parseLayerCommand } from "./layer-command.js";

const runtime = globalThis as typeof globalThis & {
  process: {
    argv: string[];
    stdout: {
      write(text: string): void;
    };
  };
};

function printJson(value: unknown): void {
  runtime.process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function parseFlags(args: string[]): {
  positionals: string[];
  flags: Record<string, string>;
} {
  const positionals: string[] = [];
  const flags: Record<string, string> = {};

  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (!value.startsWith("--")) {
      positionals.push(value);
      continue;
    }

    const name = value.slice(2);
    const next = args[index + 1];
    if (!next || next.startsWith("--")) {
      flags[name] = "true";
      continue;
    }

    flags[name] = next;
    index += 1;
  }

  return { positionals, flags };
}


async function tryCompanionJob(kind: string, payload: Record<string, unknown>, waitMs = 120_000): Promise<unknown | undefined> {
  const client = new CompanionClient({ timeoutMs: 2_000 });
  if (!(await client.isReachable())) {
    return undefined;
  }

  const job = await client.createJob({
    kind,
    payload,
    sessionId: typeof payload.sessionId === "string" ? payload.sessionId : undefined,
    client: "action-cli",
  });
  return client.waitJob(job.id, waitMs);
}


function parseVisionProvider(value: string | undefined): "minimax" | "moondream" | undefined {
  return value === "moondream" || value === "minimax" ? value : undefined;
}

/** How long a CLI-set drape stays up without an explicit `stage clear`. */
const DEFAULT_CLI_STAGE_SECONDS = 1800;

function requiredNumber(flags: Record<string, string>, key: string): number {
  const raw = flags[key];
  const value = raw === undefined ? Number.NaN : Number(raw);
  if (!Number.isFinite(value)) {
    throw new Error(`Missing or invalid --${key}`);
  }
  return value;
}

async function main(argv: string[]): Promise<void> {
  const [command, ...rest] = argv;
  const { positionals, flags } = command === "layer" ? parseLayerCommand(rest) : parseFlags(rest);
  const [arg, extra] = positionals;

  if (command === "capabilities") {
    const sourceRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
    printJson(actionCapabilities(process.env.ACTION_ROOT ?? sourceRoot, { sourceRoot }));
    return;
  }

  if (command === "demo" && arg) {
    const scenario = await loadScenario(arg);
    const result = await runScenarioGuidedCaptureDemo(
      scenario,
      extra === "macos" ? "macos" : "mock",
    );
    printJson(result);
    return;
  }

  if (command === "calculator-demo") {
    const scenario = await loadScenario("calculator-demo");
    const result = await runScenarioGuidedCaptureDemo(
      scenario,
      arg === "macos" ? "macos" : "mock",
    );
    printJson(result);
    return;
  }

  if (command === "scenario" && arg) {
    const scenario = await loadScenario(arg);
    printJson(compileScenario(scenario));
    return;
  }

  if (command === "inspect" && arg === "current-surface") {
    const payload = {
      includeOcr: flags["no-ocr"] !== "true",
      includeVision: flags.vision === "true",
      visionPrompt: flags["vision-prompt"],
      visionProvider: parseVisionProvider(flags["vision-provider"]),
      mockNative: flags.mock === "true" ? true : undefined,
    };

    if (flags.direct !== "true") {
      const companionJob = await tryCompanionJob("observe.snapshot", payload);
      if (companionJob) {
        printJson({ ok: true, companion: true, job: companionJob });
        return;
      }
    }

    const result = await inspectCurrentSurface(payload);
    printJson(result);
    return;
  }

  if (command === "vision" && arg === "log") {
    const client = new CompanionClient({ timeoutMs: 2_000 });
    const timeline = await client.timeline({
      sessionId: flags["session-id"],
      limit: flags.limit ? requiredNumber(flags, "limit") : undefined,
    });
    printJson({ ok: true, timeline });
    return;
  }

  if (command === "companion" && arg === "status") {
    const client = new CompanionClient({ timeoutMs: 2_000 });
    printJson(await client.status());
    return;
  }

  if (command === "stage") {
    const nativeHostPath = resolve(
      process.env.ACTION_NATIVE_HOST
        ?? resolve(dirname(fileURLToPath(import.meta.url)), "../../../native/engine/scripts/run-app-host.sh"),
    );
    const director = new StageDirector(nativeHostPath);
    if (arg === "set") {
      const subjects = (flags.subjects ?? flags.subject ?? "")
        .split(",")
        .map((token) => token.trim())
        .filter((token) => token.length > 0)
        .map((token) => {
          const [bundleId, title] = token.split(":");
          return title ? { bundleId, title } : { bundleId };
        });
      try {
        const status = await director.set({
          mode: flags.mode,
          color: flags.color,
          level: flags.level,
          subjects,
          // This process exits as soon as the drape is up, so it cannot be what the drape
          // watches — a caller-owned sheet would dismiss itself within one poll interval.
          // The lifetime is the backstop instead: `stage clear` is the intended teardown,
          // and a forgotten drape still expires on its own.
          owner: "detached",
          seconds: flags.seconds ?? String(DEFAULT_CLI_STAGE_SECONDS),
          bounds: flags.x
            ? {
                x: requiredNumber(flags, "x"),
                y: requiredNumber(flags, "y"),
                width: requiredNumber(flags, "width"),
                height: requiredNumber(flags, "height"),
              }
            : undefined,
        });
        printJson({ ok: true, stage: status });
      } catch (error) {
        if (error instanceof StageSceneError) {
          printJson({ ok: false, error: error.message, stage: error.stage });
          process.exitCode = 1;
          return;
        }
        throw error;
      }
      return;
    }
    if (arg === "clear") {
      printJson({ ok: true, stage: await director.clear() });
      return;
    }
    printJson({ ok: true, stage: await director.status() });
    return;
  }

  if (command === "layer") {
    const nativeHostPath = resolve(
      process.env.ACTION_NATIVE_HOST
        ?? resolve(dirname(fileURLToPath(import.meta.url)), "../../../native/engine/scripts/run-app-host.sh"),
    );
    const director = new AgentLayerDirector(nativeHostPath);
    if (arg === "prepare") {
      const display = await director.prepareDisplay({ width: flags.width, height: flags.height });
      printJson({ ok: display.active, display });
      if (!display.active) process.exitCode = 1;
      return;
    }
    if (arg === "display-status") {
      printJson({ ok: true, display: await director.displayStatus() });
      return;
    }
    if (arg === "release") {
      const display = await director.releaseDisplay();
      printJson({ ok: !display.active, display });
      if (display.active) process.exitCode = 1;
      return;
    }
    if (arg === "open") {
      const status = await director.open({
        bundleId: flags["bundle-id"],
        pid: flags.pid,
        width: flags.width,
        height: flags.height,
        pip: flags.pip,
        windowId: flags["window-id"],
        windowTitle: flags["window-title"],
        // This process exits once the layer is up, so the layer cannot watch it.
        // `layer close` is the teardown.
        owner: "detached",
      });
      printJson({ ok: true, layer: status });
      return;
    }
    if (arg === "close") {
      const status = await director.close();
      printJson({ ok: !status.active, layer: status });
      if (status.active) {
        process.exitCode = 1;
      }
      return;
    }
    if (arg === "pip") {
      printJson({ ok: true, layer: await director.showViewer() });
      return;
    }
    if (arg === "record") {
      const verb = extra;
      if (verb === "start") {
        printJson(await director.startRecording({ out: flags.out }));
        return;
      }
      if (verb === "stop") {
        printJson(await director.stopRecording());
        return;
      }
      throw new Error("Usage: layer record start [--out <file.mov>] | layer record stop");
    }
    if (arg === "snapshot") {
      const snapshot = await director.snapshot({
        windowId: flags["window-id"] ? requiredNumber(flags, "window-id") : undefined,
        full: flags.full === "true",
        out: flags.out,
      });
      printJson(snapshot);
      return;
    }
    if (arg !== "status") throw new Error(`Unknown layer command: ${arg}`);
    printJson({ ok: true, layer: await director.status() });
    return;
  }

  if (command === "settle" && arg === "current-surface") {
    const result = await settleCurrentSurfaceViewport({
      targetViewport: {
        x: requiredNumber(flags, "x"),
        y: requiredNumber(flags, "y"),
        width: requiredNumber(flags, "width"),
        height: requiredNumber(flags, "height"),
      },
      providerId: flags.provider === "mock" ? "mock" : "pie-minimax",
      maxTurns: flags["max-turns"] ? requiredNumber(flags, "max-turns") : undefined,
    });
    printJson(result);
    return;
  }

  printJson({
    commands: [
      "bun packages/cli/src/main.ts stage set [--mode drape|space] [--color RRGGBB] [--level normal|desktop] [--subjects bundleId:title,bundleId] [--seconds 1800]",
      "bun packages/cli/src/main.ts stage clear",
      "bun packages/cli/src/main.ts stage status",
      "bun packages/cli/src/main.ts capabilities",
      "bun packages/cli/src/main.ts layer prepare [--width <w> --height <h>] (connect a persistent monitor; may change desktop topology)",
      "bun packages/cli/src/main.ts layer display-status",
      "bun packages/cli/src/main.ts layer open [--bundle-id <id> | --pid <pid>] [--width <w> --height <h>] [--window-id <n> | --window-title <text>] [--pip on|off] (attach to the prepared monitor)",
      "bun packages/cli/src/main.ts layer pip",
      "bun packages/cli/src/main.ts layer snapshot [--window-id <n> | --full] [--out <file.png>]",
      "bun packages/cli/src/main.ts layer record start [--out <file.mov>] | layer record stop",
      "bun packages/cli/src/main.ts layer close (restore task windows; keep the monitor connected)",
      "bun packages/cli/src/main.ts layer release (close the task and disconnect the monitor)",
      "bun packages/cli/src/main.ts layer status",
      "bun packages/cli/src/main.ts inspect current-surface [--direct] [--mock] [--no-ocr] [--vision] [--vision-provider minimax|moondream] [--vision-prompt <prompt>]",
      "bun packages/cli/src/main.ts vision log [--session-id <id>] [--limit <n>]",
      "bun packages/cli/src/main.ts companion status",
      "bun packages/cli/src/main.ts settle current-surface --x <x> --y <y> --width <w> --height <h> [--provider mock|pie-minimax]",
      "bun run demo:calculator",
      "bun run demo:notes",
      "bun run demo:calculator:macos",
      "bun run demo:notes:macos",
      "bun run scenario:calculator",
      "bun run scenario:notes",
      "bun packages/cli/src/main.ts demo <scenario-id> [mock|macos]",
      "bun packages/cli/src/main.ts scenario <scenario-id>",
    ],
  });
}

function cliArgs(argv: string[]): string[] {
  const maybeScript = argv[1];

  if (maybeScript && (maybeScript.endsWith(".ts") || maybeScript.endsWith(".js") || maybeScript.includes("/"))) {
    return argv.slice(2);
  }

  return argv.slice(1);
}

void main(cliArgs(runtime.process.argv)).catch((error) => {
  printJson({ ok: false, error: error instanceof Error ? error.message : String(error) });
  process.exitCode = 1;
});
