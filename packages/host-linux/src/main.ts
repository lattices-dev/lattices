#!/usr/bin/env bun
// lattices-host: private local desktop runtime. Remote access is a separate gateway.
//
//   lattices-host                      listen on ~/.lattices/run/lattices.sock
//   lats gateway start --tailnet        explicitly enable paired remote access
//   lattices-host --describe           print capabilities and exit

import { BUILD_IDENTITY } from "./build-info.ts";
import { localRuntimeDirectory } from "../../desktop-client/local-ipc.ts";
import { hostname, homedir } from "node:os";
import { join } from "node:path";
import { prepareSocket, privateToken } from "./private-ipc.ts";
import { VERSION, capabilities, refreshCapabilities, registerEndpoints } from "./endpoints.ts";
import * as hypr from "./hyprland.ts";
import { updateEventHealth } from "./host-capabilities.ts";
import * as live from "./live.ts";
import { Router } from "./router.ts";
import { serve } from "./server.ts";
import { BRIDGE_PORT, registerBridgeEndpoints, startBridge } from "./bridge/server.ts";
import { visitControlDir } from "./bridge/visit-control.ts";

function parseArgs(argv: string[]) {
  const opts = { describe: false, quiet: false, bridge: true };
  for (const arg of argv) {
    if (arg === "--describe") opts.describe = true;
    else if (arg === "--quiet") opts.quiet = true;
    else if (arg === "--no-bridge") opts.bridge = false;
    else if (arg === "--version") { console.log(VERSION); process.exit(0); }
    else if (arg === "--help" || arg === "-h") {
      console.log(`lattices-host ${VERSION}
Usage: lattices-host [--quiet] [--describe] [--no-bridge]
       lattices-host mouse-home | tray | visit-test

The Linux desktop runtime listens only on private Unix sockets in ~/.lattices/run.
Use lats gateway start --tailnet for explicit authenticated remote access.
Network binding and --no-pairing are no longer supported by the desktop runtime.`);
      process.exit(0);
    } else throw new Error(`Unknown argument: ${arg}. Remote access is managed by lats gateway.`);
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
  const runtimeDir = localRuntimeDirectory();
  const socketPath = join(runtimeDir, "lattices.sock");
  const tokenFile = join(runtimeDir, "lattices.token");
  const primary = "127.0.0.1";
  const resources = registerEndpoints(router, { bindHost: primary, tailnetName: hostname(), startedAt: Date.now(), clientCount: () => clientCount(), emit: (event, data) => emit(event, data) });


  if (opts.describe) {
    console.log(JSON.stringify(await router.dispatch("host.describe", {}), null, 2));
    stopEvents();
    process.exit(0);
  }

  const log = (line: string) => {
    if (!opts.quiet) console.log(`[lattices-host] ${line}`);
  };
  await prepareSocket(socketPath);
  const server = serve({ socketPath, tokenFile, router, log });

  let bridge: ReturnType<typeof startBridge> | null = null;
  if (opts.bridge) {
    const bridgeSocket = join(runtimeDir, "companion.sock");
    await prepareSocket(bridgeSocket);
    bridge = startBridge({
      hosts: [], socketPath: bridgeSocket,
      token: privateToken(join(runtimeDir, "companion.token")),
      controlDir: visitControlDir(), name: hostname(), version: VERSION,
      trackpadAvailable: () => capabilities.has("input.pointer"),
      hasTmux: () => capabilities.has("sessions.tmux"),
      log: (line) => log(`bridge: ${line}`),
    });
    registerBridgeEndpoints(router, bridge, BRIDGE_PORT, []);
    log(`companion bridge on private IPC ${bridgeSocket}`);
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

  log(`v${VERSION} listening on private IPC ${socketPath}`);
  log("build: " + (BUILD_IDENTITY.commit ?? "unknown commit") + (BUILD_IDENTITY.dirty === true ? " (dirty)" : BUILD_IDENTITY.dirty === null ? " (dirty unknown)" : ""));
  log(`capabilities: ${[...capabilities].sort().join(", ") || "none"}`);

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
