#!/usr/bin/env bun

import { execFile, spawn } from "node:child_process";
import { access, readdir, rm, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const runtime = globalThis as typeof globalThis & {
  process: {
    argv: string[];
    cwd(): string;
    env: Record<string, string | undefined>;
    exit(code?: number): never;
    stdout: { write(text: string): void };
    stderr: { write(text: string): void };
  };
};

const rootDir = resolve(dirname(new URL(import.meta.url).pathname), "../../..");
const engineDir = resolve(rootDir, "native/engine");
const engineScriptsDir = resolve(engineDir, "scripts");
const appDir = resolve(rootDir, "native/dist/Action.app");
const appExecutable = resolve(appDir, "Contents/MacOS/Action");

function print(text: string): void {
  runtime.process.stdout.write(`${text}\n`);
}

function printError(text: string): void {
  runtime.process.stderr.write(`${text}\n`);
}

function usage(): string {
  return [
    "Native Action.app developer commands. Run them with bun from products/action.",
    "",
    "Usage:",
    "  bun run native:app:build",
    "  bun run native:rebuild",
    "  bun run native:launch [-- --no-build]",
    "  bun run native:relaunch [-- --no-build]",
    "  bun run native:quit",
    "  bun run native:permissions:status",
    "  bun run native:doctor",
    "  bun run native:verify",
    "  bun run native:logs",
    "  bun run native:host -- <args...>",
    "  bun run native:agent -- <args...>",
    "  bun run native:agent-cli -- <args...>",
    "",
    "Examples:",
    "  bun run native:app:build",
    "  bun run native:relaunch",
    "  bun run native:host -- guided-calculator-demo",
    "  bun run native:logs",
  ].join("\n");
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function newestFileMtimeMs(root: string): Promise<number> {
  let newest = 0;
  const queue = [root];

  while (queue.length > 0) {
    const current = queue.shift();
    if (!current) {
      continue;
    }

    const entries = await readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = resolve(current, entry.name);
      if (entry.isDirectory()) {
        queue.push(fullPath);
        continue;
      }
      const info = await stat(fullPath);
      newest = Math.max(newest, info.mtimeMs);
    }
  }

  return newest;
}

async function appNeedsBuild(): Promise<boolean> {
  if (!(await pathExists(appExecutable))) {
    return true;
  }

  const executableStat = await stat(appExecutable);
  const executableMtimeMs = executableStat.mtimeMs;
  const watchFiles = [
    resolve(engineDir, "Package.swift"),
    resolve(engineDir, "App/Info.plist"),
    resolve(engineDir, "AgentApp/Info.plist"),
  ];

  for (const watchFile of watchFiles) {
    if (!(await pathExists(watchFile))) {
      continue;
    }
    const fileStat = await stat(watchFile);
    if (fileStat.mtimeMs > executableMtimeMs) {
      return true;
    }
  }

  const watchDirs = [
    resolve(engineDir, "Sources"),
    resolve(engineDir, "CoreSources"),
    resolve(engineDir, "AgentSources"),
    resolve(engineDir, "AgentCLISources"),
  ];

  for (const watchDir of watchDirs) {
    if (!(await pathExists(watchDir))) {
      continue;
    }
    if ((await newestFileMtimeMs(watchDir)) > executableMtimeMs) {
      return true;
    }
  }

  return false;
}

async function runScript(scriptName: string, args: string[] = [], stdio: "inherit" | "pipe" = "inherit"): Promise<void> {
  const scriptPath = resolve(engineScriptsDir, scriptName);
  if (stdio === "pipe") {
    const { stdout } = await execFileAsync(scriptPath, args, { cwd: rootDir });
    if (stdout) {
      runtime.process.stdout.write(stdout);
    }
    return;
  }

  await new Promise<void>((resolvePromise, reject) => {
    const child = spawn(scriptPath, args, {
      cwd: rootDir,
      stdio: "inherit",
    });
    child.on("exit", (code) => {
      if (code === 0) {
        resolvePromise();
        return;
      }
      reject(new Error(`${scriptName} exited with code ${code ?? 1}`));
    });
    child.on("error", reject);
  });
}

async function ensureBuiltIfNeeded(): Promise<void> {
  if (await appNeedsBuild()) {
    await runScript("build-app.sh");
  }
}

async function politeQuitAction(): Promise<boolean> {
  // The native command identifies launcher processes. A display owner keeps the
  // same executable name alive deliberately; pgrep/pkill would destroy it.
  try {
    await runScript("run-app-host.sh", ["quit-app"], "pipe");
    return true;
  } catch {
    return false;
  }
}

async function openLauncher(): Promise<void> {
  await execFileAsync("open", ["-n", "-a", appDir, "--args", "launcher"]);
}

async function streamLogs(): Promise<void> {
  await new Promise<void>((resolvePromise, reject) => {
    const child = spawn("/usr/bin/log", [
      "stream",
      "--style",
      "compact",
      "--level",
      "debug",
      "--predicate",
      'process == "Action" AND subsystem == "dev.lattices.Action"',
    ], {
      cwd: rootDir,
      stdio: "inherit",
    });
    child.on("exit", (code) => {
      if (code === 0 || code === null) {
        resolvePromise();
        return;
      }
      reject(new Error(`log stream exited with code ${code}`));
    });
    child.on("error", reject);
  });
}

async function main(argv: string[]): Promise<void> {
  const [command = "help", ...args] = argv;

  switch (command) {
    case "help":
    case "-h":
    case "--help":
      print(usage());
      return;
    case "path":
      print(resolve(rootDir, "packages/cli/src/action-dev.ts"));
      return;
    case "alias":
      print("Use package.json scripts from products/action, for example: bun run native:relaunch");
      return;
    case "build":
      await runScript("build-app.sh");
      return;
    case "rebuild":
      await rm(resolve(rootDir, "native/.action-build.lock"), { force: true });
      await rm(appDir, { force: true, recursive: true });
      await execFileAsync("swift", ["package", "--package-path", engineDir, "reset"], { cwd: rootDir });
      await runScript("build-app.sh");
      return;
    case "launch":
      if (args[0] !== "--no-build") {
        await ensureBuiltIfNeeded();
      }
      await openLauncher();
      return;
    case "relaunch":
      if (args[0] !== "--no-build") {
        await ensureBuiltIfNeeded();
      }
      if (!(await politeQuitAction())) {
        throw new Error("Action launcher could not be stopped; preserving independent displays and recordings.");
      }
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 350));
      await openLauncher();
      return;
    case "quit":
      if (!(await politeQuitAction())) {
        printError("Action launcher did not quit. Independent displays and recordings were preserved.");
        runtime.process.exit(1);
      }
      return;
    case "status":
      await runScript("run-app-host.sh", ["status"]);
      return;
    case "doctor":
      await runScript("doctor.sh");
      return;
    case "verify":
      await runScript("verify-app.sh");
      return;
    case "hud":
      await new Promise<void>((resolvePromise, reject) => {
        const child = spawn("bun", ["run", "hud"], {
          cwd: rootDir,
          stdio: "inherit",
        });
        child.on("exit", (code) => {
          if (code === 0) {
            resolvePromise();
            return;
          }
          reject(new Error(`hud exited with code ${code ?? 1}`));
        });
        child.on("error", reject);
      });
      return;
    case "logs":
      await streamLogs();
      return;
    case "host":
      await runScript("run-app-host.sh", args);
      return;
    case "agent":
      await runScript("run-agent.sh", args);
      return;
    case "agent-cli":
      await runScript("run-agent-cli.sh", args);
      return;
    default:
      printError(`Unknown native developer command: ${command}`);
      printError("");
      printError(usage());
      runtime.process.exit(1);
  }
}

function cliArgs(argv: string[]): string[] {
  const maybeScript = argv[1];

  if (maybeScript && (maybeScript.endsWith(".ts") || maybeScript.endsWith(".js") || maybeScript.includes("/"))) {
    return argv.slice(2);
  }

  return argv.slice(1);
}

void main(cliArgs(runtime.process.argv));
