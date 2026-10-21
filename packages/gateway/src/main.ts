import { spawn } from "node:child_process";
import { openSync, closeSync, constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { daemonCallTo } from "../../desktop-client/daemon-client.ts";
import { localEndpoint } from "../../desktop-client/local-ipc.ts";
import { selfIdentity } from "../../host-linux/src/auth.ts";
import { privateDirectory } from "../../host-linux/src/private-ipc.ts";
import { startGateway } from "./server.ts";

const help = `Usage: lats gateway start --tailnet [--port 9399] [--allow-user ID|LOGIN] [--allow-tag TAG]
       lats gateway run --tailnet [...]       foreground service
       lats gateway status | stop | clients
       lats gateway approve CLIENT_ID | deny CLIENT_ID | revoke CLIENT_ID

The gateway is a separate opt-in per-user process. It binds only the verified
Tailscale IP, which is encrypted by WireGuard. Clients must additionally pair
and sign each connection. No insecure LAN, wildcard, or --no-pairing mode.
Approve requests locally after checking fingerprints and exact method grants.
Use lats --host HOST pair --read-only, then lats --host HOST call METHOD.
For other products use gateway.call {product,method,params}; request exact
product:method grants when pairing, e.g. pair --grant action:status.
Unknown methods are denied.`;

export async function gatewayMain(argv = process.argv.slice(2)) {
  const [command = "status", ...args] = argv;
  if (["help", "--help", "-h"].includes(command)) { console.log(help); return; }
  const endpoint = localEndpoint("gateway");
  const control = (method: string, params?: Record<string, unknown>) => daemonCallTo(endpoint, method, params, 2000);
  if (command === "status") {
    try { console.log(JSON.stringify(await control("gateway.status"), null, 2)); }
    catch (error) { if (["ENOENT", "ECONNREFUSED"].includes((error as NodeJS.ErrnoException).code ?? "")) console.log(JSON.stringify({ service: "lattices-gateway", running: false })); else throw error; }
    return;
  }
  if (["stop", "clients", "approve", "deny", "revoke"].includes(command)) {
    const mutation = ["approve", "deny", "revoke"].includes(command);
    if ((mutation && args.length !== 1) || (!mutation && args.length)) throw new Error(help);
    console.log(JSON.stringify(await control(command === "stop" ? "gateway.stop" : command === "clients" ? "clients.list" : `clients.${command}`, mutation ? { clientID: args[0] } : undefined), null, 2));
    return;
  }
  if (command !== "start" && command !== "run") throw new Error(help);
  let tailnet = false, port = 9399;
  const allowUsers: string[] = [], allowTags: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--tailnet") tailnet = true;
    else if (["--port", "--allow-user", "--allow-tag"].includes(arg!)) {
      const value = args[++i]; if (!value) throw new Error(`${arg} needs a value`);
      if (arg === "--port") port = Number(value);
      else if (arg === "--allow-user") allowUsers.push(value);
      else allowTags.push(value);
    } else throw new Error(`Unknown gateway option ${arg}`);
  }
  if (!tailnet) throw new Error("Remote access requires explicit --tailnet. " + help);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid gateway port");
  const self = await selfIdentity();
  const address = self.ips.find(ip => ip.includes("."));
  if (!address) throw new Error("Tailscale is not connected with an IPv4 address");
  const stateDir = join(homedir(), ".lattices", "gateway");
  if (command === "start") {
    try { await control("gateway.status"); throw new Error("Gateway is already running"); }
    catch (error) { if (!["ENOENT", "ECONNREFUSED"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error; }
    privateDirectory(stateDir);
    const log = openSync(join(stateDir, "service.log"), constants.O_WRONLY | constants.O_CREAT | constants.O_APPEND | constants.O_NOFOLLOW, 0o600);
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), "run", ...args], { detached: true, stdio: ["ignore", log, log], env: process.env });
    closeSync(log);
    let spawnError: Error | undefined;
    child.once("error", error => { spawnError = error; }); child.unref();
    for (let i = 0; i < 40; i++) {
      if (spawnError) throw spawnError;
      try { const status = await control("gateway.status"); console.log(JSON.stringify(status, null, 2)); return; }
      catch { await Bun.sleep(100); }
    }
    child.kill("SIGTERM");
    throw new Error(`Gateway did not start. Inspect ${join(stateDir, "service.log")}`);
  }
  const server = await startGateway({ address, port, name: self.hostname, dnsName: self.dnsName, policy: { allowUsers: allowUsers.length ? allowUsers : [self.userId], allowTags }, stateDir, verifiedIPs: self.ips });
  process.on("SIGINT", server.stop); process.on("SIGTERM", server.stop);
  console.log(JSON.stringify({ service: "lattices-gateway", address: server.address, port: server.port, fingerprint: server.fingerprint }));
}

if (import.meta.main) gatewayMain().catch(error => { console.error(`lattices-gateway: ${(error as Error).message}`); process.exitCode = 1; });
