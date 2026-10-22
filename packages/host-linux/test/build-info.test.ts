import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BUILD_IDENTITY, VERSION, sourceBuildIdentity } from "../src/build-info.ts";
import releaseInfo from "../../../package.json";
import { capabilities, registerEndpoints } from "../src/endpoints.ts";
import { Router } from "../src/router.ts";

function git(root: string, ...args: string[]) {
  const result = spawnSync("git", ["-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", ...args], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stdout.trim();
}

test("build version is the lattices release version; identity is immutable", () => {
  expect(VERSION).toBe(releaseInfo.version);
  expect(BUILD_IDENTITY.version).toBe(VERSION);
  expect(Object.isFrozen(BUILD_IDENTITY)).toBe(true);
});

test("Git snapshots distinguish clean/dirty and do not change when HEAD moves", () => {
  const root = mkdtempSync(join(tmpdir(), "lats-build-"));
  try {
    git(root, "init", "-q");
    mkdirSync(join(root, "packages/host-linux"), { recursive: true });
    writeFileSync(join(root, "packages/host-linux/test.txt"), "first");
    git(root, "add", ".");
    git(root, "commit", "-qm", "first");
    const first = sourceBuildIdentity(root);
    expect(first).toEqual({ version: VERSION, commit: git(root, "rev-parse", "HEAD"), dirty: false });
    writeFileSync(join(root, "packages/host-linux/test.txt"), "second");
    expect(sourceBuildIdentity(root).dirty).toBe(true);
    git(root, "commit", "-qam", "second");
    const second = sourceBuildIdentity(root);
    expect(second.commit).not.toBe(first.commit);
    expect(first.dirty).toBe(false);
    writeFileSync(join(root, "packages/host-linux/new.ts"), "// untracked source");
    expect(sourceBuildIdentity(root).dirty).toBe(true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("no Git checkout means an explicit unknown revision, not the cwd revision", () => {
  const root = mkdtempSync(join(tmpdir(), "lats-build-"));
  try { expect(sourceBuildIdentity(root)).toEqual({ version: VERSION, commit: null, dirty: null }); }
  finally { rmSync(root, { recursive: true, force: true }); }
});

test("describe and status publish the same startup build without changing RPC schema", async () => {
  capabilities.clear();
  const router = new Router(() => capabilities);
  registerEndpoints(router, { bindHost: "127.0.0.1", startedAt: Date.now(), clientCount: () => 0 });
  const before = router.schema();
  for (const method of ["host.describe", "daemon.status"]) {
    const result = await router.dispatch(method, {}) as Record<string, unknown>;
    expect(result.build).toEqual(BUILD_IDENTITY);
    expect(result.version).toBe(VERSION);
  }
  expect(router.schema()).toEqual(before);
});

test("bundle embeds an identity and runs with no Git checkout or git on PATH", async () => {
  const root = mkdtempSync(join(tmpdir(), "lats-bundle-"));
  const identity = { version: VERSION, commit: "a".repeat(40), dirty: false };
  try {
    const result = await Bun.build({
      entrypoints: [join(import.meta.dir, "../src/build-info.ts")],
      target: "bun",
      define: { LATTICES_HOST_BUILD_IDENTITY: JSON.stringify(identity) },
    });
    expect(result.success).toBe(true);
    const bundle = join(root, "identity.js");
    await Bun.write(bundle, result.outputs[0]);
    const proc = Bun.spawn([process.execPath, "-e", "const m = await import(process.argv[1]); console.log(JSON.stringify(m.BUILD_IDENTITY));", bundle], { cwd: root, env: { ...process.env, PATH: "/not-a-command-path" }, stdout: "pipe", stderr: "pipe" });
    const stdout = await new Response(proc.stdout).text();
    expect(await proc.exited).toBe(0);
    expect(JSON.parse(stdout)).toEqual(identity);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
