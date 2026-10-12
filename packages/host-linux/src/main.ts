#!/usr/bin/env bun
// lattices-host: expose this Linux desktop to other lattices machines (LAT-013).
//
//   lattices-host                      listen on the tailnet address and loopback
//   lattices-host --bind 127.0.0.1     loopback only
//   lattices-host --allow-user you@github --allow-tag tag:lattices
//   lattices-host --describe           print capabilities and exit

import { BUILD_IDENTITY } from "./build-info.ts";
import { selfIdentity, type Policy } from "./auth.ts";
import { VERSION, capabilities, refreshCapabilities, registerEndpoints } from "./endpoints.ts";
import * as hypr from "./hyprland.ts";
import { updateEventHealth } from "./host-capabilities.ts";
import * as live from "./live.ts";
import { Router } from "./router.ts";
import { serve } from "./server.ts";
import { DaemonPairing, registerPairingEndpoints } from "./pairing.ts";
import { BRIDGE_PORT, registerBridgeEndpoints, startBridge } from "./bridge/server.ts";

const DEFAULT_PORT = 9399;

function parseArgs(argv: string[]) {
  const opts = { binds: [] as string[], port: DEFAULT_PORT, allowUsers: [] as string[], allowTags: [] as string[], describe: false, quiet: false, pairing: true, bridge: true, bridgeBinds: [] as string[], bridgePort: BRIDGE_PORT, bridgeStateDir: undefined as string | undefined };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${arg} needs a value`);
      return v;
    };
    if (arg === "--bind") opts.binds.push(value());
    else if (arg === "--port") opts.port = Number(value());
    else if (arg === "--allow-user") opts.allowUsers.push(value());
    else if (arg === "--allow-tag") opts.allowTags.push(value());
    else if (arg === "--describe") opts.describe = true;
    else if (arg === "--no-bridge") opts.bridge = false;
    else if (arg === "--no-pairing") opts.pairing = false;
    else if (arg === "--bridge-bind") opts.bridgeBinds.push(value());
    else if (arg === "--bridge-port") opts.bridgePort = Number(value());
    else if (arg === "--bridge-state-dir") opts.bridgeStateDir = value();
    else if (arg === "--quiet") opts.quiet = true;
    else if (arg === "--version") {
      console.log(VERSION);
      process.exit(0);
    } else if (arg === "--help" || arg === "-h") {
      console.log(`lattices-host ${VERSION}

Usage: lattices-host [--bind ADDR]... [--port N] [--allow-user ID|LOGIN]... [--allow-tag TAG]...
                     [--no-pairing] [--no-bridge] [--bridge-bind ADDR]... [--bridge-port N] [--bridge-state-dir DIR] [--describe]
       lattices-host visit-test [--host ADDR:PORT] [--name NAME]
       lattices-host mouse-home
       lattices-host tray

By default listens on this machine's tailnet IPv4 address and on 127.0.0.1,
port ${DEFAULT_PORT}, and admits only devices owned by this machine's Tailscale user.
Past that, a remote client must pair once (\`lats --host <this host> pair\`,
approved on this desktop or with \`lats call clients.approve\` here) and then
signs every connection. Loopback is trusted. --no-pairing skips pairing (dev).

The iOS companion bridge listens on the same addresses, port ${BRIDGE_PORT}. Devices
pair with an approval on this desktop (or bridge.pairing.approve) and then sign
and encrypt every request, as with a Mac. --bridge-bind adds addresses, such as
a LAN IP for a phone without Tailscale.`);
      process.exit(0);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  return opts;
}

async function main() {
  if (process.argv[2] === "__virtual-space-worker") {
    const { runVirtualSpaceWorker } = await import("./virtual-space-worker.ts");
    await runVirtualSpaceWorker();
    return;
  }
  if (process.argv[2] === "visit-test") {
    const { runVisitTest } = await import("./bridge/visit-test.ts");
    await runVisitTest(process.argv.slice(3));
    return;
  }
  // Local primitives stay available when the network host is stopped.
  if (process.argv[2]?.startsWith("mouse-")) {
    const { runMouseCommand } = await import("./mouse-cli.ts");
    console.log(JSON.stringify(await runMouseCommand(process.argv.slice(2)), null, 2));
    return;
  }
  if (process.argv[2] === "tray") {
    if (process.argv.length !== 3) throw new Error("Usage: lattices-host tray");
    const { startTray } = await import("./tray/main.ts");
    await startTray();
    return;
  }
  const opts = parseArgs(process.argv.slice(2));
  await refreshCapabilities();
  let emit = (_event: string, _data: unknown) => {};
  let onDesktopEvent = (_event: string) => {};
  const stopEvents = hypr.onEvents((event) => onDesktopEvent(event), {
    onHealth: (health) => {
      updateEventHealth(health);
      emit("host.healthChanged", { eventStream: health });
    },
    log: (line) => { if (!opts.quiet) console.error("[lattices-host] " + line); },
  });
  await stopEvents.ready;

  const router = new Router(() => capabilities);
  let clientCount = () => 0;
  const policy: Policy = { allowUsers: [...opts.allowUsers], allowTags: [...opts.allowTags] };

  let binds = opts.binds;
  let self: Awaited<ReturnType<typeof selfIdentity>> | null = null;
  try {
    self = await selfIdentity();
  } catch {
    self = null;
  }
  if (binds.length === 0) {
    const tailnet = self?.ips.find((ip) => ip.includes("."));
    binds = tailnet ? [tailnet, "127.0.0.1"] : ["127.0.0.1"];
  }
  if (policy.allowUsers.length === 0 && self) policy.allowUsers.push(self.userId);

  const primary = binds.find((b) => b !== "127.0.0.1") ?? binds[0];
  const resources = registerEndpoints(router, { bindHost: primary, tailnetName: self?.hostname, startedAt: Date.now(), clientCount: () => clientCount(), emit: (event, data) => emit(event, data) });

  if (opts.describe) {
    console.log(JSON.stringify(await router.dispatch("host.describe", {}), null, 2));
    stopEvents();
    process.exit(0);
  }

  const log = (line: string) => {
    if (!opts.quiet) console.log(`[lattices-host] ${line}`);
  };
  const pairing = opts.pairing ? new DaemonPairing(self?.hostname ?? "lattices-host") : null;
  const server = serve({ hosts: binds, port: opts.port, policy, router, pairing, log });
  if (pairing) registerPairingEndpoints(router, pairing, server.disconnect);

  let bridge: ReturnType<typeof startBridge> | null = null;
  if (opts.bridge) {
    const bridgeHosts = [...new Set([...binds, ...opts.bridgeBinds])];
    bridge = startBridge({
      hosts: bridgeHosts,
      port: opts.bridgePort,
      stateDir: opts.bridgeStateDir,
      name: self?.hostname,
      version: VERSION,
      trackpadAvailable: () => capabilities.has("input.pointer"),
      hasTmux: () => capabilities.has("sessions.tmux"),
      log: (line) => log(`bridge: ${line}`),
    });
    registerBridgeEndpoints(router, bridge, opts.bridgePort, bridgeHosts);
    log(`companion bridge on ${bridgeHosts.map((h) => `http://${h}:${opts.bridgePort}`).join(", ")} (fingerprint ${bridge.security.fingerprint})`);
  }
  clientCount = server.clientCount;
  emit = server.broadcast;

  // Hyprland events become the daemon's windows.changed / spaces.changed.
  let pending: ReturnType<typeof setTimeout> | null = null;
  const changed = new Set<string>();
  onDesktopEvent = (event) => {
    if (/^(openwindow|closewindow|movewindow|windowtitle|activewindow|changefloatingmode|fullscreen)/.test(event)) changed.add("windows.changed");
    if (/^(workspace|createworkspace|destroyworkspace|focusedmon|monitoradded|monitorremoved|moveworkspace)/.test(event)) changed.add("spaces.changed");
    if (changed.size === 0 || pending) return;
    pending = setTimeout(() => {
      for (const name of changed) server.broadcast(name, { source: "hyprland" });
      changed.clear();
      pending = null;
    }, 150);
  };

  log(`v${VERSION} listening on ${binds.map((b) => `ws://${b}:${opts.port}`).join(", ")}`);
  log("build: " + (BUILD_IDENTITY.commit ?? "unknown commit") + (BUILD_IDENTITY.dirty === true ? " (dirty)" : BUILD_IDENTITY.dirty === null ? " (dirty unknown)" : ""));
  log(`capabilities: ${[...capabilities].sort().join(", ") || "none"}`);
  log(`admits: ${[...policy.allowUsers, ...policy.allowTags].join(", ") || "loopback only"}${self?.login ? ` (owner ${self.login})` : ""}`);
  log(
    pairing
      ? `pairing required for remote clients (fingerprint ${pairing.security.fingerprint}, ${pairing.clients().length} paired)`
      : "pairing OFF: admitted remote clients get full access"
  );

  let stopping = false;
  const shutdown = async () => {
    if (stopping) return;
    stopping = true;
    stopEvents();
    if (pending) clearTimeout(pending);
    live.stop();
    await resources.virtualSpace.stop();
    await bridge?.stop();
    server.stop();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error(`lattices-host: ${(err as Error).message}`);
  process.exit(1);
});
