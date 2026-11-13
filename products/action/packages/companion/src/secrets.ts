import { existsSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";

import type { ActionCompanionDatabase, SecretStatusRecord } from "./db.js";

export interface LoadedSecrets {
  values: Record<string, string>;
  statuses: SecretStatusRecord[];
  loadedAt: string;
}

const DEFAULT_SECRET_NAMES = [
  "ACTION_VISION_PROVIDER",
  "ACTION_MOONDREAM_PYTHON",
  "MOONDREAM_PYTHON",
  "ACTION_CHROME_COMPANION_PROFILE",
] as const;

function fingerprint(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}

function parseSecretFile(path: string): Record<string, string> {
  if (!existsSync(path)) {
    return {};
  }
  const raw = readFileSync(path, "utf8");
  const trimmed = raw.trim();
  if (!trimmed) {
    return {};
  }

  if (trimmed.startsWith("{")) {
    const parsed = JSON.parse(trimmed) as Record<string, unknown>;
    return Object.fromEntries(
      Object.entries(parsed).filter((entry): entry is [string, string] => typeof entry[1] === "string" && entry[1].length > 0),
    );
  }

  const result: Record<string, string> = {};
  for (const line of raw.split(/\r?\n/g)) {
    const clean = line.trim();
    if (!clean || clean.startsWith("#")) {
      continue;
    }
    const equals = clean.indexOf("=");
    if (equals <= 0) {
      continue;
    }
    const key = clean.slice(0, equals).trim();
    let value = clean.slice(equals + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (key && value) {
      result[key] = value;
    }
  }
  return result;
}

export function loadCompanionSecrets(input: {
  env?: NodeJS.ProcessEnv;
  secretFile?: string;
  names?: string[];
  db?: ActionCompanionDatabase;
} = {}): LoadedSecrets {
  const env = input.env ?? process.env;
  const secretFile = input.secretFile ?? env.ACTION_SECRETS_FILE ?? env.ACTION_COMPANION_SECRETS_FILE;
  const fileSecrets = secretFile ? parseSecretFile(secretFile) : {};
  const names = Array.from(new Set([...(input.names ?? DEFAULT_SECRET_NAMES), ...Object.keys(fileSecrets)]));
  const loadedAt = new Date().toISOString();
  const values: Record<string, string> = {};
  const statuses: SecretStatusRecord[] = [];

  for (const name of names) {
    const envValue = env[name];
    const fileValue = fileSecrets[name];
    const value = typeof envValue === "string" && envValue.length > 0 ? envValue : fileValue;
    if (value) {
      values[name] = value;
      process.env[name] = value;
      statuses.push({
        name,
        present: true,
        source: envValue ? "env" : `file:${secretFile}`,
        loadedAt,
        fingerprint: fingerprint(value),
      });
    } else {
      statuses.push({
        name,
        present: false,
        loadedAt,
      });
    }
  }

  for (const status of statuses) {
    input.db?.upsertSecretStatus(status);
  }

  return { values, statuses, loadedAt };
}
