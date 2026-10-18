#!/usr/bin/env node

// Quick connection test for the Lattices daemon.
// Run: node scripts/connect.js
//
// Verifies the daemon is reachable and prints workspace status.

import { daemonCall, isDaemonRunning } from "@lattices/lattices";

async function main() {
  if (!(await isDaemonRunning())) {
    console.error("Lattices daemon is not running.");
    console.error("Start it with: lattices app");
    process.exit(1);
  }

  const status = await daemonCall("daemon.status");
  console.log(`Daemon up for ${Math.round(status.uptime)}s`);
  console.log(`  Windows: ${status.windowCount}`);
  console.log(`  Sessions: ${status.tmuxSessionCount}`);
  console.log(`  Clients: ${status.clientCount}`);

  const projects = await daemonCall("projects.list");
  const running = projects.filter((p) => p.isRunning);
  console.log(`\nProjects: ${projects.length} discovered, ${running.length} running`);

  for (const project of running) {
    console.log(`  ${project.name} (${project.paneCount} panes) — ${project.path}`);
  }

  const { layers, active } = await daemonCall("layers.list");
  if (layers.length > 0) {
    console.log(`\nLayers: ${layers.length}`);
    for (const layer of layers) {
      const marker = layer.index === active ? " *" : "";
      console.log(`  ${layer.label} (${layer.projectCount} entries)${marker}`);
    }
  }
}

main().catch((err) => {
  console.error("Error:", err.message);
  process.exit(1);
});
