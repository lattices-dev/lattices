import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

export const layerAcceptancePath = () => join(homedir(), "Library/Application Support/Action/agent-layer/isolation-acceptance.json");

export interface LayerAcceptanceBinding {
  executableSha256: string;
  nativeSourceDigest: string;
  orchestrationSourceDigest: string;
  hostFingerprint: string;
  osBuild: string;
  displayConfigurationDigest: string;
}

export interface LayerAcceptanceRecord {
  schemaVersion: 1;
  outcome: "passed";
  acceptedAt: string;
  expiresAt: string;
  reviewer: string;
  binding: LayerAcceptanceBinding;
  checks: Record<"physicalDisplayMode" | "scale" | "arrangement" | "frontmostApp" | "pointer" | "unrelatedWindowFrames", "unchanged-throughout">;
  phases: ["open", "interaction", "close"];
  evidence: { path: string; sha256: string }[];
}

const bindingKeys = ["executableSha256", "nativeSourceDigest", "orchestrationSourceDigest", "hostFingerprint", "osBuild", "displayConfigurationDigest"] as const;
const checkKeys = ["physicalDisplayMode", "scale", "arrangement", "frontmostApp", "pointer", "unrelatedWindowFrames"] as const;
const sha256Pattern = /^[a-f0-9]{64}$/;

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (object(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}

export function displayConfigurationDigest(configuration: unknown): string {
  return createHash("sha256").update(canonicalJSON(configuration)).digest("hex");
}

function validRecord(value: unknown): value is LayerAcceptanceRecord {
  if (!object(value) || value.schemaVersion !== 1 || value.outcome !== "passed" || !object(value.binding) || !object(value.checks)) return false;
  if (typeof value.reviewer !== "string" || !value.reviewer.trim()) return false;
  if (typeof value.acceptedAt !== "string" || !Number.isFinite(Date.parse(value.acceptedAt))) return false;
  if (typeof value.expiresAt !== "string" || !Number.isFinite(Date.parse(value.expiresAt)) || Date.parse(value.expiresAt) <= Date.parse(value.acceptedAt)) return false;
  const binding = value.binding;
  if (!bindingKeys.every(key => typeof binding[key] === "string" && (key === "osBuild" ? binding[key].trim().length > 0 : sha256Pattern.test(binding[key])))) return false;
  const checks = value.checks;
  if (!checkKeys.every(key => checks[key] === "unchanged-throughout")) return false;
  if (!Array.isArray(value.phases) || value.phases.join(",") !== "open,interaction,close") return false;
  return Array.isArray(value.evidence) && value.evidence.length > 0 && value.evidence.every(entry =>
    object(entry) && typeof entry.path === "string" && isAbsolute(entry.path) && typeof entry.sha256 === "string" && sha256Pattern.test(entry.sha256));
}

export function layerAcceptance(binding: Partial<LayerAcceptanceBinding>, options: { path?: string; now?: number; contextError?: string } = {}) {
  const path = options.path ?? layerAcceptancePath();
  const missing = bindingKeys.filter(key => !binding[key]);
  const contextError = options.contextError ?? (missing.length ? `Current acceptance context unavailable: ${missing.join(", ")}` : undefined);
  const base = {
    path, schemaVersion: 1, currentBinding: binding,
    context: { state: contextError ? "unavailable" as const : "available" as const, reason: contextError ?? null },
    runningProcessVerified: false,
    note: "Matches operator-recorded acceptance evidence to this bundle, orchestration, host and display configuration. Does not certify the running app, independently evaluate evidence, or override quarantine.",
  };
  let value: unknown;
  try {
    value = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    const missing = (error as NodeJS.ErrnoException).code === "ENOENT";
    return { ...base, state: missing ? "missing" as const : "invalid" as const, reasons: [missing ? "No host-local isolation acceptance record exists." : "Acceptance record is unreadable or invalid JSON."] };
  }
  if (!validRecord(value)) return { ...base, state: "invalid" as const, reasons: ["Acceptance record does not satisfy schemaVersion 1, required checks, phases or evidence references."] };
  const now = options.now ?? Date.now();
  if (Date.parse(value.acceptedAt) > now) return { ...base, state: "invalid" as const, reasons: ["Acceptance timestamp is in the future."] };
  for (const artifact of value.evidence) {
    try {
      if (createHash("sha256").update(readFileSync(artifact.path)).digest("hex") !== artifact.sha256) {
        return { ...base, state: "invalid" as const, reasons: [`Acceptance evidence digest changed: ${artifact.path}`] };
      }
    } catch {
      return { ...base, state: "invalid" as const, reasons: [`Acceptance evidence is missing or unreadable: ${artifact.path}`] };
    }
  }
  if (contextError) return { ...base, state: "unverified" as const, reasons: [contextError] };
  const mismatched = bindingKeys.filter(key => binding[key] !== value.binding[key]);
  const reasons = mismatched.map(key => `Acceptance binding changed: ${key}`);
  if (Date.parse(value.expiresAt) <= now) reasons.push("Acceptance record expired.");
  return {
    ...base, state: reasons.length ? "stale" as const : "accepted" as const, reasons,
    acceptedAt: value.acceptedAt, expiresAt: value.expiresAt, reviewer: value.reviewer, evidence: value.evidence,
  };
}
