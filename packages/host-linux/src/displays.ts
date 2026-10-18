// Virtual displays: headless Hyprland outputs the host creates for remote
// viewers. The host only removes outputs it created (or was told to adopt);
// ownership lives in ~/.lattices/host-displays.json so it survives restarts.

import { mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { run } from "./exec.ts";
import * as hypr from "./hyprland.ts";
import { RouterError } from "./router.ts";

export const REGISTRY_PATH = join(homedir(), ".lattices", "host-displays.json");

export interface Owned {
  name: string;
  createdAt: number;
  adopted?: boolean;
}

export function readOwned(path = REGISTRY_PATH): Owned[] {
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { outputs?: Owned[] };
    return Array.isArray(parsed.outputs) ? parsed.outputs.filter((o) => typeof o?.name === "string") : [];
  } catch {
    return [];
  }
}

function writeOwned(outputs: Owned[], path = REGISTRY_PATH) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = path + ".tmp";
  writeFileSync(temporary, JSON.stringify({ outputs }, null, 2) + "\n");
  renameSync(temporary, path);
}

/** Output names Hyprland accepts and Lua quoting can't break. */
export function validName(name: string): boolean {
  return /^[A-Za-z0-9_-]{1,32}$/.test(name);
}

/** The first LATS-n not taken by a live output. */
export function nextName(taken: string[]): string {
  for (let n = 1; ; n++) if (!taken.includes(`LATS-${n}`)) return `LATS-${n}`;
}

export interface Spec {
  width: number;
  height: number;
  scale: number;
  refresh: number;
}

/** The monitor rule, as Lua (0.55+, which refuses `keyword`) or a legacy keyword. */
export function monitorRule(name: string, spec: Spec, lua: boolean): string[] {
  const mode = `${Math.round(spec.width)}x${Math.round(spec.height)}@${Math.round(spec.refresh)}`;
  return lua
    ? ["eval", `hl.monitor({ output = ${JSON.stringify(name)}, mode = ${JSON.stringify(mode)}, position = "auto", scale = ${spec.scale} })`]
    : ["keyword", "monitor", `${name},${mode},auto,${spec.scale}`];
}

async function hyprctl(args: string[]) {
  const out = (await run("hyprctl", args)).trim();
  if (out !== "ok") throw new Error(`hyprctl ${args[0]}: ${out}`);
}

async function waitForOutput(name: string, present: boolean) {
  for (let i = 0; i < 20; i++) {
    const live = (await hypr.monitors()).some((m) => m.name === name);
    if (live === present) return;
    await Bun.sleep(50);
  }
  throw new Error(`output ${name} did not ${present ? "appear" : "go away"}`);
}

/** One service owns a registry. Serialize complete mutations, including name allocation. */
export function displayService(deps: {
  path: string;
  monitors: typeof hypr.monitors;
  usesLua: typeof hypr.usesLua;
  command: (args: string[]) => Promise<void>;
  wait: (name: string, present: boolean) => Promise<void>;
  write?: (outputs: Owned[], path: string) => void;
}) {
  let tail: Promise<unknown> = Promise.resolve();
  const serialized = <T>(fn: () => Promise<T>): Promise<T> => {
    const result = tail.then(fn);
    tail = result.catch(() => {});
    return result;
  };
  const persist = (outputs: Owned[]) => (deps.write ?? writeOwned)(outputs, deps.path);
  return {
    create: (opts: { name?: string; spec: Spec; adopt?: boolean }) => serialized(async () => {
      const monitors = await deps.monitors();
      const owned = readOwned(deps.path);
      const name = opts.name ?? nextName([...monitors.map((m) => m.name), ...owned.map((o) => o.name)]);
      if (!validName(name)) throw new RouterError(`Invalid display name: ${name}`);
      const existing = monitors.some((m) => m.name === name);
      const registered = owned.some((o) => o.name === name);
      if (existing && !registered && !opts.adopt) {
        throw new RouterError(`Display ${name} already exists and was not created by this host; pass adopt: true to manage it`);
      }
      // Durable recovery intent precedes any compositor mutation. A failed write
      // cannot leave a newly created, unowned output.
      if (!registered) persist([...owned, { name, createdAt: Date.now(), ...(existing ? { adopted: true } : {}) }]);
      const trace: string[] = [];
      try {
        if (!existing) {
          await deps.command(["output", "create", "headless", name]);
          trace.push(`output create headless ${name}`);
          await deps.wait(name, true);
        }
        const rule = monitorRule(name, opts.spec, await deps.usesLua());
        await deps.command(rule);
        trace.push(rule.join(" "));
        return { name, created: !existing, adopted: existing, trace };
      } catch (error) {
        if (!existing) {
          try {
            if ((await deps.monitors()).some((m) => m.name === name)) {
              await deps.command(["output", "remove", name]);
              await deps.wait(name, false);
            }
          } catch (cleanup) {
            throw new AggregateError([error, cleanup], `Display ${name} creation and rollback failed; ownership retained for recovery`);
          }
          // If persistence fails, retain the conservative recovery record.
          if (!registered) persist(owned);
        }
        throw error;
      }
    }),
    remove: (name: string) => serialized(async () => {
      const owned = readOwned(deps.path);
      if (!owned.some((o) => o.name === name)) {
        throw new RouterError(`Display ${name} was not created by this host; refusing to remove it`);
      }
      const live = (await deps.monitors()).some((m) => m.name === name);
      if (live) {
        await deps.command(["output", "remove", name]);
        await deps.wait(name, false);
      }
      persist(owned.filter((o) => o.name !== name));
      return { name, removed: live };
    }),
  };
}

const service = displayService({
  path: REGISTRY_PATH, monitors: hypr.monitors, usesLua: hypr.usesLua,
  command: hyprctl, wait: waitForOutput,
});
export const create = service.create;
export const remove = service.remove;
