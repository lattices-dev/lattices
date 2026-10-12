import { callHost, resolveHost, type HostEntry } from "../hosts.ts";
export type DaemonClient = typeof import("../daemon-client.ts");

let target: HostEntry | undefined;
export function targetHost(name: string): void { target = name === "local" ? undefined : resolveHost(name); _client = undefined; }
export function isRemoteTarget(): boolean { return target !== undefined; }

let _client: DaemonClient | undefined;

/** Lazy-load daemon client — avoids import cost for pure tmux commands. */
export async function loadDaemonClient(): Promise<DaemonClient> {
  if (!_client) {
    const local = await import("../daemon-client.ts");
    _client = target ? { ...local, daemonCall: (method, params, timeout) => callHost(target!, method, params, timeout),
      isDaemonRunning: async () => { await callHost(target!, "daemon.status"); return true; } } : local;
  }
  return _client;
}

/**
 * Run when the daemon is reachable. Returns null when the daemon is down or the
 * RPC fails — use for commands that fall back to tmux (ls, status).
 */
export async function tryDaemon<T>(
  fn: (client: DaemonClient) => Promise<T>
): Promise<T | null> {
  const client = await loadDaemonClient();
  if (!(await client.isDaemonRunning())) return null;
  try {
    return await fn(client);
  } catch (error) {
    if (target) throw error;
    return null;
  }
}

export async function withDaemon<T>(
  fn: (client: DaemonClient) => Promise<T>,
  opts?: { message?: string; exitCode?: number }
): Promise<T> {
  const message = opts?.message ?? "Daemon not running. Start with: lats app";
  const exitCode = opts?.exitCode ?? 1;

  const client = await loadDaemonClient();
  if (!(await client.isDaemonRunning())) {
    console.error(message);
    process.exit(exitCode);
  }

  try {
    return await fn(client);
  } catch (e: unknown) {
    console.error(`Error: ${(e as Error).message}`);
    process.exit(exitCode);
  }
}