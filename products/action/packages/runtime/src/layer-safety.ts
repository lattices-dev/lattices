import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const layerSafetyPath = () => join(homedir(), "Library/Application Support/Action/agent-layer/isolation-block.json");

/** Host-local safety quarantine, distinct from whether a binary implements layers. */
export function layerSafety(path = layerSafetyPath()) {
  if (!existsSync(path)) return { blocked: false, state: "not-quarantined", path, reason: "No host quarantine recorded; this is not proof of isolation acceptance." };
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    if (!value || typeof value.blocked !== "boolean") throw new Error("blocked must be a boolean");
    return { blocked: value.blocked as boolean, state: value.blocked ? "blocked" : "not-quarantined", path,
      reason: typeof value.reason === "string" ? value.reason : "Host private-display preservation has not passed acceptance.",
      evidence: typeof value.evidence === "string" ? value.evidence : undefined };
  } catch {
    return { blocked: true, state: "blocked", path, reason: "The host isolation safety record is invalid or unreadable; refusing display creation." };
  }
}

export function assertLayerSafety(path = layerSafetyPath()): void {
  const safety = layerSafety(path);
  if (safety.blocked) throw new Error(`Private layers are disabled on this host: ${safety.reason} No virtual display was created. Safety record: ${safety.path}`);
}
