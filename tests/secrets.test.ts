import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { PROVIDER_CREDENTIALS } from "../bin/infer.ts";
import { clearRegisteredSecrets, redact, registerSecret } from "../bin/redact.ts";

const schema = readFileSync(join(import.meta.dir, "..", ".env.schema"), "utf8");

/** Each declared variable with the decorator lines just above it. */
function declarations(): Map<string, string[]> {
  const out = new Map<string, string[]>();
  let pending: string[] = [];
  for (const line of schema.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith("#")) {
      pending.push(trimmed);
      continue;
    }
    const match = /^([A-Z][A-Z0-9_]*)=/.exec(trimmed);
    if (match) out.set(match[1], pending);
    pending = [];
  }
  return out;
}

afterEach(() => clearRegisteredSecrets());

test("every provider key is declared sensitive in .env.schema", () => {
  const declared = declarations();
  for (const [provider, { env, account }] of Object.entries(PROVIDER_CREDENTIALS)) {
    const decorators = declared.get(env);
    expect(decorators, `${provider}: ${env} missing from .env.schema`).toBeDefined();
    expect(decorators!.some((d) => d.includes("@sensitive"))).toBe(true);
    expect(schema).toContain(`-s lattices.inference -a ${account} -w`);
  }
});

test(".env.schema holds no values", () => {
  for (const line of schema.split("\n")) {
    const match = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line.trim());
    if (!match) continue;
    const value = match[2];
    expect(value === "" || value.startsWith("exec(`/usr/bin/security find-generic-password"), `${match[1]} has a value`).toBe(true);
  }
});

test("redact replaces registered values and ignores short ones", () => {
  registerSecret("gsk_example_secret_value");
  registerSecret("short");
  expect(redact("Bearer gsk_example_secret_value failed twice: gsk_example_secret_value"))
    .toBe("Bearer [redacted] failed twice: [redacted]");
  expect(redact("a short note")).toBe("a short note");
});
