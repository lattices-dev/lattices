import { mkdirSync, readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { dirname } from "node:path";
import { configuredHosts, discoverTailnetHosts, hostStatuses, HOSTS_FILE, resolveHost, callHost } from "../hosts.ts";
import { hasFlag } from "./helpers.ts";
import { CLIENT_FILE, PAIRED_HOSTS_FILE, pairingRequest, savePairedHost } from "../host-pairing.ts";

/**
 * lats hosts [--discover] [--json]   list reachable lattices hosts (LAT-013)
 * lats hosts describe <name>         host.describe for one host
 * lats hosts pair [name] [--read-only | --drive] [--grant product:method]  pair with a gateway
 */
export async function hostsCommand(args: string[]): Promise<void> {
  const json = hasFlag(args, "json");
  if (args[0] === "add") {
    const [_, name, address = name, rawPort = "9399"] = args;
    const port = Number(rawPort);
    if (!name || name === "local" || !address || !Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error("Usage: lats hosts add <name> [address] [port]");
    }
    const root = existsSync(HOSTS_FILE) ? JSON.parse(readFileSync(HOSTS_FILE, "utf8")) : {};
    if (!root || typeof root !== "object" || Array.isArray(root)) throw new Error("Invalid hosts.json");
    if (root.hosts !== undefined && (!root.hosts || typeof root.hosts !== "object" || Array.isArray(root.hosts))) throw new Error("Invalid hosts.json hosts object");
    root.hosts = { ...root.hosts, [name]: { address, port } };
    mkdirSync(dirname(HOSTS_FILE), { recursive: true });
    const temp = `${HOSTS_FILE}.${process.pid}.tmp`;
    writeFileSync(temp, JSON.stringify(root, null, 2) + "\n", { mode: 0o600 });
    renameSync(temp, HOSTS_FILE);
    console.log(`Added ${name} at ${address}:${port}`);
    return;
  }
  if (args[0] === "pair") {
    await pairCommand(args.slice(1));
    return;
  }
  if (args[0] === "describe") {
    const host = resolveHost(args[1]);
    console.log(JSON.stringify(await callHost(host, "host.describe"), null, 2));
    return;
  }
  let hosts = configuredHosts();
  if (hasFlag(args, "discover")) {
    const names = new Set(hosts.map((h) => h.name));
    hosts = [...hosts, ...(await discoverTailnetHosts()).filter((h) => !names.has(h.name))];
  }
  const statuses = await hostStatuses(hosts);
  if (json) {
    console.log(JSON.stringify(statuses, null, 2));
    return;
  }
  for (const s of statuses) {
    const state = s.reachable ? "\x1b[32m●\x1b[0m" : "\x1b[31m○\x1b[0m";
    const detail = s.reachable ? `${s.platform ?? "?"}${s.capabilities ? `  ${s.capabilities.length} capabilities` : ""}` : `unreachable (${s.error})`;
    console.log(`${state} ${s.name.padEnd(14)} ${`${s.address}:${s.port}`.padEnd(22)} ${s.source.padEnd(8)} ${detail}`);
  }
  if (statuses.length === 1 && !hasFlag(args, "discover")) {
    console.log(`\nAdd hosts in ${HOSTS_FILE} ({"hosts":{"archie":{"address":"archie"}}}), LATTICES_HOSTS=archie,..., or run with --discover.`);
  }
}

/**
 * Ask a gateway to trust this machine. A person approves with
 * `lats gateway approve` on the host; this waits.
 */
export function parsePairOptions(args: string[]): { name?: string; scope: "read" | "act" | "drive"; grants?: string[] } {
  let name: string | undefined;
  const grants: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--grant" || arg.startsWith("--grant=")) {
      const grant = arg === "--grant" ? args[++i] : arg.slice(8);
      if (!grant || !/^(lattices|action|blink|speech):[a-zA-Z][a-zA-Z0-9_.]*$/.test(grant)) throw new Error("--grant requires an exact product:method, for example action:status");
      grants.push(grant);
    } else if (["--read-only", "--drive"].includes(arg)) continue;
    else if (arg.startsWith("--")) throw new Error(`Unknown pairing option: ${arg}`);
    else if (name) throw new Error("Specify one host to pair");
    else name = arg;
  }
  if (hasFlag(args, "read-only") && hasFlag(args, "drive")) throw new Error("Choose --read-only or --drive");
  if (grants.length && (hasFlag(args, "read-only") || hasFlag(args, "drive"))) throw new Error("Choose exact --grant permissions or a scope shorthand");
  return { name, scope: grants.length || hasFlag(args, "read-only") ? "read" : hasFlag(args, "drive") ? "drive" : "act", ...(grants.length ? { grants: [...new Set(grants)] } : {}) };
}

async function pairCommand(args: string[]): Promise<void> {
  const { name, scope, grants } = parsePairOptions(args);
  const host = resolveHost(name);
  const { params, fingerprint } = pairingRequest(scope);
  const where = `${host.address}:${host.port}`;
  console.log(`Pairing ${params.clientName} with ${where} (${grants?.join(", ") ?? scope}).`);
  console.log(`This client's code: ${fingerprint} \u2014 approve on the host only if its notification shows the same code.`);
  console.log(`(On the host: lats gateway clients, then lats gateway approve ${params.clientID})`);
  const result = (await callHost(host, "clients.pair", { ...params, ...(grants ? { grants } : {}) }, 135_000)) as {
    disposition: string;
    host: string;
    hostPublicKey: string;
    hostFingerprint: string;
    scope: "read" | "act" | "drive" | null;
    detail?: string;
    grants?: string[];
  };
  if (result.disposition === "denied" || !result.scope) {
    console.error(`Not paired: ${result.detail ?? "denied"}`);
    process.exit(1);
  }
  savePairedHost(
    { host: host.address, port: host.port },
    { host: result.host, hostPublicKey: result.hostPublicKey, hostFingerprint: result.hostFingerprint, scope: result.scope, pairedAt: new Date().toISOString() }
  );
  console.log(`Paired with ${result.host} (host code ${result.hostFingerprint}, permissions ${result.grants?.join(", ") ?? result.scope}).`);
  console.log(`Keys: ${CLIENT_FILE}, ${PAIRED_HOSTS_FILE}`);
  if (!result.grants || result.grants.includes("lattices:host.describe")) {
    console.log(`Check: lats --host ${host.address}:${host.port} call host.describe`);
  } else {
    console.log("Use gateway.call with one of the approved product and method grants above.");
  }
}
