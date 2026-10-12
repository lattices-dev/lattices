import { readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir, hostname } from "node:os";
import { callHost, configuredHosts, type HostEntry } from "../hosts.ts";

type Pairing = { name: string; address: string; side?: string; placement?: unknown; unplaced?: boolean };
const key = (s: string) => s.trim().toLowerCase();
function address(s: string): string {
  try { return key(new URL(s.includes("://") ? s : `http://${s}`).hostname).replace(/\.$/, ""); }
  catch { return key(s); }
}

/** Loopback says nothing about which machine it is: a pairing through an ssh tunnel is 127.0.0.1 too. */
const loopback = (a: string) => a === "localhost" || a === "::1" || a === "[::1]" || a.startsWith("127.");
const named = (aliases: string[]) => aliases.filter(a => a && !loopback(a));

/** Merge aliases transitively, retaining the daemon port from hosts.json. */
export function mergeMachines(hosts: HostEntry[], paired: Pairing[], localName: string) {
  type Source = { host?: HostEntry; pair?: Pairing; aliases: string[] };
  const sources: Source[] = [
    ...hosts.map(host => ({ host, aliases: host.source === "local" ? [key(host.name), key(localName)] : named([key(host.name), address(host.address)]) })),
    ...paired.map(pair => ({ pair, aliases: named([key(pair.name), address(pair.address)]) })),
  ];
  const groups: { aliases: Set<string>; sources: Source[] }[] = [];
  for (const source of sources) {
    const group = { aliases: new Set(source.aliases), sources: [source] };
    for (let i = 0; i < groups.length;) {
      if ([...groups[i].aliases].some(a => group.aliases.has(a))) {
        const other = groups.splice(i, 1)[0];
        other.aliases.forEach(a => group.aliases.add(a)); group.sources.push(...other.sources); i = 0;
      } else i++;
    }
    groups.push(group);
  }
  return groups.map(group => {
    const pair = group.sources.find(s => s.pair)?.pair;
    const host = group.sources.find(s => s.host?.source === "local")?.host ?? group.sources.find(s => s.host)?.host;
    return { host: host ?? { name: pair!.name, address: address(pair!.address), port: 9399, source: "config" as const }, pair };
  });
}

export async function machineStatuses(hosts: HostEntry[], paired: Pairing[], localName: string, call = callHost, placements: Record<string, unknown> = {}) {
  return Promise.all(mergeMachines(hosts, paired, localName).map(async ({ host, pair }) => {
    const row = { name: host.source === "local" ? localName : pair?.name ?? host.name, address: host.address,
      local: host.source === "local", paired: !!pair, placement: host.source === "local" ? "here" : pair?.placement ?? placements[host.name] ?? (pair ? placements[pair.name] : undefined) ?? (pair?.unplaced ? null : pair?.side) ?? null };
    try {
      const info = await call(host, "host.describe", null, 2500) as any;
      return { ...row, reachable: true, os: info.platform ?? null, version: info.build?.version ?? info.version ?? null,
        commit: info.build?.commit ?? null, displays: Array.isArray(info.displays) ? info.displays.length : null };
    } catch (error) {
      return { ...row, reachable: (error as Error).message.includes("Unknown method"), os: null, version: null, commit: null, displays: null, error: (error as Error).message };
    }
  }));
}

export async function machinesCommand(json: boolean) {
  const hosts = configuredHosts();
  let paired: Pairing[] = [];
  try { paired = JSON.parse(readFileSync(join(homedir(), ".lattices/visit/hosts.json"), "utf8")).hosts ?? []; } catch {}
  let pairingError: string | undefined;
  let placements: Record<string, unknown> = {};
  try {
    const status = await callHost(hosts.find(h => h.source === "local")!, "visit.status", null, 2500) as any;
    paired = status.hosts ?? []; placements = status.placements ?? {};
  }
  catch (error) { pairingError = (error as Error).message; }
  const machines = await machineStatuses(hosts, paired, hostname(), callHost, placements);
  if (json) console.log(JSON.stringify({ machines, ...(pairingError ? { pairingError } : {}) }, null, 2));
  else {
    if (pairingError) console.error(`Visit pairings unavailable: ${pairingError}`);
    for (const m of machines) console.log(`  ${m.name}${m.local ? " (local)" : ""}  ${m.reachable ? "reachable" : "unreachable"}  ${m.os ?? "?"}  ${m.version ?? "?"}/${m.commit?.slice(0, 8) ?? "?"}  ${m.displays ?? "?"} displays  ${m.paired ? "paired" : "unpaired"}  ${typeof m.placement === "string" ? m.placement : m.placement ? `at ${(m.placement as any).x},${(m.placement as any).y}` : "unplaced"}`);
  }
}
