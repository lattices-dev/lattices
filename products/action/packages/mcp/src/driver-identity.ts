import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { basename } from "node:path";

export interface DriverIdentity {
  agent: string;
  task?: string;
  /** The folder the harness was started in, e.g. "talkie". */
  project?: string;
  source: "handshake" | "environment" | "client" | "fallback";
}

export const UNIDENTIFIED_AGENT = "Unidentified MCP caller";

const clean = (value: string | undefined): string | undefined => {
  const result = value?.trim().replace(/\s+/g, " ");
  return result ? result.slice(0, 96) : undefined;
};

/** Names harnesses send as MCP `clientInfo.name` when they send no `title`. */
const KNOWN_CLIENTS: Record<string, string> = {
  "claude-code": "Claude Code",
  "codex-mcp-client": "Codex",
};

/** A readable name for the MCP client that connected, from its `initialize` handshake. */
export function clientLabel(info: { name?: string; title?: string } | undefined): string | undefined {
  const title = clean(info?.title);
  if (title) {
    return title;
  }
  const name = clean(info?.name);
  return name ? (KNOWN_CLIENTS[name] ?? name) : undefined;
}

/**
 * The project the harness is working in.
 *
 * The MCP server runs with Action's own cwd, so the useful folder is the parent's:
 * the harness process that spawned this server over stdio.
 */
export function inferProject(
  env: NodeJS.ProcessEnv = process.env,
  parentCwd: () => string | undefined = () => processCwd(process.ppid),
): string | undefined {
  const explicit = clean(env.ACTION_DRIVER_PROJECT);
  if (explicit) {
    return explicit;
  }
  const cwd = parentCwd();
  if (!cwd || cwd === "/" || cwd === homedir()) {
    return undefined;
  }
  return clean(basename(cwd));
}

function processCwd(pid: number): string | undefined {
  if (!Number.isInteger(pid) || pid <= 1) {
    return undefined;
  }
  try {
    const output = execFileSync("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], {
      encoding: "utf8",
      timeout: 1000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    return output.split("\n").find((line) => line.startsWith("n"))?.slice(1);
  } catch {
    return undefined;
  }
}

/** Resolve a stable label without pretending an unidentified caller is known. */
export function inferDriverIdentity(env: NodeJS.ProcessEnv = process.env): DriverIdentity {
  const explicit = clean(env.ACTION_DRIVER_LABEL ?? env.ACTION_AGENT_LABEL);
  if (explicit) {
    return {
      agent: explicit,
      task: clean(env.ACTION_DRIVER_TASK),
      source: "environment",
    };
  }

  const scout = clean(env.OPENSCOUT_AGENT);
  if (scout) {
    return { agent: scout, source: "fallback" };
  }

  const codex = clean(env.CODEX_THREAD_ID);
  if (codex) {
    return { agent: `Codex ${codex.slice(0, 8)}`, source: "fallback" };
  }

  if (clean(env.CLAUDECODE)) {
    return { agent: "Claude Code", source: "fallback" };
  }

  return { agent: UNIDENTIFIED_AGENT, source: "fallback" };
}

/**
 * Who is driving, in order of trust: what the caller says (drive_begin, identify),
 * a deployment label, the MCP client's own handshake, then environment hints.
 */
export class DriverIdentityContext {
  private identity: DriverIdentity;
  private readonly project: string | null | undefined;

  /** Pass `project: null` to skip looking it up. */
  constructor(env: NodeJS.ProcessEnv = process.env, project: string | null | undefined = inferProject(env)) {
    this.project = project;
    this.identity = this.withProject(inferDriverIdentity(env));
  }

  get(): DriverIdentity {
    return this.identity;
  }

  /** Adopt the MCP client's handshake name, unless something more trusted already named the driver. */
  adoptClient(info: { name?: string; title?: string } | undefined): DriverIdentity {
    const label = clientLabel(info);
    if (label && this.identity.source === "fallback") {
      this.identity = this.withProject({ agent: label, source: "client" });
    }
    return this.identity;
  }

  identify(agent: string, task?: string): DriverIdentity {
    const resolved = clean(agent);
    if (!resolved) {
      throw new Error("agent must be a non-empty human-readable label");
    }
    this.identity = this.withProject({
      agent: resolved,
      task: clean(task),
      source: "handshake",
    });
    return this.identity;
  }

  private withProject(identity: DriverIdentity): DriverIdentity {
    return this.project ? { ...identity, project: this.project } : identity;
  }
}
