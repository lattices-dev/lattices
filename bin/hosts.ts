// The lattices hosts a client can address (LAT-013): the local daemon, hosts
// named in ~/.lattices/hosts.json or LATTICES_HOSTS, and, on request, the
// caller's own tailnet devices that answer on the daemon port.

import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { connect } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { daemonCallTo, daemonEndpoint } from "./daemon-client.ts";

export const DEFAULT_PORT = 9399;
export const HOSTS_FILE = join(homedir(), ".lattices", "hosts.json");

export interface HostEntry {
  name: string;
  address: string;
  port: number;
  source: "local" | "config" | "env" | "tailnet";
  socketPath?: string;
  tokenFile?: string;
}

export interface HostStatus extends HostEntry {
  reachable: boolean;
  platform?: string;
  capabilities?: string[];
  error?: string;
}

/** `name`, `name:port`, or `name=address[:port]`. */
export function parseHostSpec(spec: string, source: HostEntry["source"]): HostEntry | null {
  const trimmed = spec.trim();
  if (!trimmed) return null;
  const [name, target] = trimmed.includes("=") ? trimmed.split("=", 2) : [trimmed.split(":")[0], trimmed];
  const [address, port] = target.split(":");
  if (!name || !address) return null;
  return { name, address, port: port ? Number(port) : DEFAULT_PORT, source };
}

export function configuredHosts(
  env: Record<string, string | undefined> = process.env,
  readConfig: () => string | null = () => {
    try {
      return readFileSync(HOSTS_FILE, "utf8");
    } catch {
      return null;
    }
  }
): HostEntry[] {
  const local = daemonEndpoint(env);
  const hosts = new Map<string, HostEntry>([["local", { name: "local", address: local.host, port: local.port, source: "local", ...(local.socketPath ? {socketPath: local.socketPath} : {}), ...(local.tokenFile ? {tokenFile: local.tokenFile} : {}) }]]);
  const raw = readConfig();
  if (raw) {
    const parsed = JSON.parse(raw) as { hosts?: Record<string, { address?: string; port?: number }> };
    for (const [name, value] of Object.entries(parsed.hosts ?? {})) {
      hosts.set(name, { name, address: value.address ?? name, port: value.port ?? DEFAULT_PORT, source: "config" });
    }
  }
  for (const spec of (env.LATTICES_HOSTS ?? "").split(",")) {
    const entry = parseHostSpec(spec, "env");
    if (entry) hosts.set(entry.name, entry);
  }
  return [...hosts.values()];
}

/** Resolve a host by name; an unknown name is taken as an address. */
export function resolveHost(name: string | undefined, hosts = configuredHosts()): HostEntry {
  if (!name || name === "local") return hosts.find((h) => h.name === "local")!;
  return hosts.find((h) => h.name === name) ?? parseHostSpec(name, "env")!;
}

export function callHost(host: HostEntry, method: string, params?: Record<string, unknown> | null, timeoutMs = 10_000) {
  return daemonCallTo({ host: host.address, port: host.port, socketPath: host.socketPath, tokenFile: host.tokenFile }, method, params, timeoutMs);
}

function portOpen(address: string, port: number, timeoutMs: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host: address, port });
    const done = (open: boolean) => {
      socket.destroy();
      resolve(open);
    };
    socket.setTimeout(timeoutMs, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

/**
 * The caller's own online tailnet devices (same Tailscale user) that accept a
 * connection on the daemon port. Only probes devices you own, one port each.
 */
export async function discoverTailnetHosts(timeoutMs = 600): Promise<HostEntry[]> {
  const out = await new Promise<string>((resolve) => {
    execFile("tailscale", ["status", "--json"], { timeout: 5000 }, (err, stdout) => resolve(err ? "" : String(stdout)));
  });
  if (!out) return [];
  const status = JSON.parse(out) as {
    Self?: { UserID?: number };
    Peer?: Record<string, { HostName?: string; DNSName?: string; TailscaleIPs?: string[]; Online?: boolean; UserID?: number; Tags?: string[] }>;
  };
  const me = status.Self?.UserID;
  const peers = Object.values(status.Peer ?? {}).filter((p) => p.Online && p.UserID === me && !(p.Tags?.length) && p.TailscaleIPs?.length);
  const found = await Promise.all(
    peers.map(async (peer) => {
      const address = peer.TailscaleIPs!.find((ip) => ip.includes(".")) ?? peer.TailscaleIPs![0];
      const open = await portOpen(address, DEFAULT_PORT, timeoutMs);
      const name = peer.HostName ?? peer.DNSName?.split(".")[0] ?? address;
      return open ? ({ name, address, port: DEFAULT_PORT, source: "tailnet" } as HostEntry) : null;
    })
  );
  return found.filter((h): h is HostEntry => h !== null);
}

/** Reachability and identity for each host, probed in parallel. */
export async function hostStatuses(hosts: HostEntry[], timeoutMs = 2500): Promise<HostStatus[]> {
  return Promise.all(
    hosts.map(async (host) => {
      try {
        const describe = (await callHost(host, "host.describe", null, timeoutMs)) as { platform?: string; capabilities?: string[] };
        return { ...host, reachable: true, platform: describe.platform, capabilities: describe.capabilities };
      } catch (err) {
        const message = (err as Error).message;
        if (message === "Unknown method: host.describe") {
          // A Mac daemon: it answers, but predates host.describe.
          return { ...host, reachable: true, platform: "macos" };
        }
        return { ...host, reachable: false, error: message };
      }
    })
  );
}
