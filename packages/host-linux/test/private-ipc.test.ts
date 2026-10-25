import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdtempSync, readdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { authorizeLocalRequest, privateToken, removeLegacyToken } from "../src/private-ipc.ts";

function fixture() {
  const directory = mkdtempSync("/tmp/lats-token-");
  chmodSync(directory, 0o700);
  return directory;
}
const request = (token: string) => new Request("http://localhost/", { headers: { host: "localhost", "x-lattices-token": token } });

test("privateToken creates the shared credential once, privately, and never replaces it", () => {
  const directory = fixture();
  try {
    const file = join(directory, "lattices.token");
    const first = privateToken(file);
    expect(first).toMatch(/^[a-f0-9]{64}$/);
    expect(privateToken(file)).toBe(first);
    expect(readdirSync(directory)).toEqual(["lattices.token"]);
    chmodSync(file, 0o644);
    expect(() => privateToken(file)).toThrow("Unsafe IPC token");
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test("admission reads the current credential, so replacing the file revokes at once", () => {
  const directory = fixture();
  try {
    const file = join(directory, "lattices.token");
    const first = privateToken(file);
    const credential = () => privateToken(file);
    expect(authorizeLocalRequest(request(first), credential)).toBe(true);
    const rotated = "c".repeat(64);
    writeFileSync(`${file}.next`, rotated, { mode: 0o600 });
    renameSync(`${file}.next`, file);
    expect(authorizeLocalRequest(request(first), credential)).toBe(false);
    expect(authorizeLocalRequest(request(rotated), credential)).toBe(true);
    // An unsafe credential denies instead of throwing out of the handler.
    chmodSync(file, 0o644);
    expect(authorizeLocalRequest(request(rotated), credential)).toBe(false);
    expect(authorizeLocalRequest(request(""), "")).toBe(false);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test("removeLegacyToken deletes a stale per-service file or link and ignores absence", () => {
  const directory = fixture();
  try {
    const legacy = join(directory, "companion.token");
    writeFileSync(legacy, "b".repeat(64), { mode: 0o600 });
    removeLegacyToken(legacy);
    expect(existsSync(legacy)).toBe(false);
    removeLegacyToken(legacy);
    symlinkSync("/dev/null", legacy);
    removeLegacyToken(legacy);
    expect(readdirSync(directory)).toEqual([]);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
