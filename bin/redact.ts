/**
 * Secret redaction for anything Lattices writes to a log or an error.
 *
 * Credentials are registered by value when they are loaded (inference keys,
 * gateway tokens, pairing keys); `redact()` replaces every registered value
 * with a fixed marker. Names come from `.env.schema`, where each credential is
 * declared `@sensitive`; tests keep the code and the schema in step.
 */

const MARKER = "[redacted]";
// Shorter values match too much ordinary text to be worth scrubbing.
const MIN_LENGTH = 8;

const secrets = new Set<string>();

export function registerSecret(value: string | undefined | null): void {
  const trimmed = value?.trim();
  if (trimmed && trimmed.length >= MIN_LENGTH) secrets.add(trimmed);
}

export function redact(text: string): string {
  let out = text;
  for (const secret of secrets) {
    if (out.includes(secret)) out = out.split(secret).join(MARKER);
  }
  return out;
}

export function registeredSecretCount(): number {
  return secrets.size;
}

/** Test seam. */
export function clearRegisteredSecrets(): void {
  secrets.clear();
}
