#!/usr/bin/env bun

import { copyFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

import { daemonCall } from "../../../packages/desktop-client/daemon-client.ts";
const ACTOR_ID = "action-mira";
const PET_ID = "mira";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "..");
const sourceMetadataPath = join(repoRoot, "assets/pets/mira/pet.json");
const sourceSpritesheetPath = join(
  repoRoot,
  "assets/pets/explorer-cat/sprites/explorer-cat.sheet.webp"
);
const installedPetRoot = join(homedir(), ".codex/pets/mira");

const [command = "show", ...rest] = process.argv.slice(2);

try {
  switch (command) {
    case "install":
      await installMiraPet();
      console.log(JSON.stringify({ ok: true, petRoot: installedPetRoot }, null, 2));
      break;
    case "show":
      await installMiraPet();
      await assertLatticesDaemon();
      console.log(JSON.stringify(await showMira(rest.join(" ").trim()), null, 2));
      break;
    case "hide":
      await assertLatticesDaemon();
      console.log(JSON.stringify(await hideMira(), null, 2));
      break;
    case "move":
      await assertLatticesDaemon();
      console.log(JSON.stringify(await moveMira(rest), null, 2));
      break;
    case "status":
      console.log(JSON.stringify(await daemonCall("daemon.status"), null, 2));
      break;
    default:
      printUsageAndExit();
  }
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(message);
  process.exit(1);
}

async function installMiraPet() {
  if (!existsSync(sourceMetadataPath)) {
    throw new Error(`Missing Mira metadata: ${sourceMetadataPath}`);
  }
  if (!existsSync(sourceSpritesheetPath)) {
    throw new Error(`Missing Mira spritesheet source: ${sourceSpritesheetPath}`);
  }

  await mkdir(installedPetRoot, { recursive: true });
  await copyFile(sourceMetadataPath, join(installedPetRoot, "pet.json"));
  await copyFile(sourceSpritesheetPath, join(installedPetRoot, "spritesheet.webp"));
}

async function showMira(message) {
  const result = await daemonCall("overlay.actor.publish", {
    id: ACTOR_ID,
    renderer: "sprite",
    asset: PET_ID,
    state: "idle",
    name: "Mira",
    message: message || "Ready on the lattice.",
    placement: "bottom",
    style: "playful",
    ttlMs: 0,
    opacity: 1,
    zIndex: 540,
    dismissible: false,
  });
  return { ok: true, petRoot: installedPetRoot, result };
}

async function hideMira() {
  const result = await daemonCall("overlay.clear", { id: ACTOR_ID });
  return { ok: true, result };
}

async function moveMira(args) {
  const x = Number(args[0]);
  const y = Number(args[1]);
  const durationMs = Number(args[2] ?? 900);
  if (!Number.isFinite(x) || !Number.isFinite(y)) {
    throw new Error("Usage: bun run mira:move -- <x> <y> [durationMs]");
  }

  const result = await daemonCall("overlay.actor.moveTo", {
    id: ACTOR_ID,
    x,
    y,
    durationMs: Number.isFinite(durationMs) ? durationMs : 900,
    easing: "spring",
  });
  return { ok: true, result };
}

async function assertLatticesDaemon() {
  try {
    await daemonCall("daemon.status", null, 1200);
  } catch {
    throw new Error(
      "Lattices private local connection is not reachable. Start it with `lattices app`, then rerun this command."
    );
  }
}

function printUsageAndExit() {
  console.log(usageText());
  process.exit(1);
}

function usageText() {
  return [
    "Usage: bun scripts/mira-overlay.mjs <command>",
    "",
    "Commands:",
    "  install                 Install Mira into ~/.codex/pets/mira",
    "  show [message]          Show Mira through Lattices overlay.actor.publish",
    "  move <x> <y> [ms]       Move the persistent Mira actor",
    "  hide                    Clear the persistent Mira actor",
    "  status                  Print Lattices daemon status",
  ].join("\n");
}
