import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..");
const profileKeys = [
  "HUDSONKIT_WITH_VOICE", "LATTICES_BUNDLE", "LATTICES_TIER",
  "LATTICES_HUDSON_SOURCE", "LATTICES_HUDSON_PATH", "HUDSON_VOX_SOURCE",
  "LATTICES_VOX_SOURCE", "HUDSON_VOX_PATH", "HUDSON_VOX_GIT_URL",
  "HUDSON_VOX_GIT_REVISION", "HUDSON_VOX_GIT_BRANCH", "HUDSON_VOX_PACKAGE",
  "LONG_RENDER_DIR", "MACHINES_RENDER_DIR", "OVERVIEW_RENDER_DIR",
];

// Run the real shell entrypoint and feature resolver against a temporary
// manifest. Swift is replaced with a recorder: no compiler or desktop probes.
function runProfile(manifest: object, args: string[], overrides: Record<string, string> = {}) {
  const root = mkdtempSync(join(tmpdir(), "lattices-native-profile-"));
  try {
    for (const path of ["scripts", "bin", "apps/mac"]) mkdirSync(join(root, path), { recursive: true });
    for (const path of ["scripts/test-app.sh", "bin/lattices-build-env.ts"]) {
      copyFileSync(join(repoRoot, path), join(root, path));
    }
    writeFileSync(join(root, "apps/mac/build.json"), JSON.stringify(manifest));
    writeFileSync(join(root, "bin/swift"), `#!/usr/bin/env node
console.log(JSON.stringify({args: process.argv.slice(2), env: Object.fromEntries(
  ${JSON.stringify(profileKeys)}.filter(key => process.env[key] !== undefined).map(key => [key, process.env[key]])
)}));
`, { mode: 0o755 });
    const env = { ...process.env };
    for (const key of profileKeys) delete env[key];
    return spawnSync("bash", [join(root, "scripts/test-app.sh"), ...args], {
      encoding: "utf8",
      env: { ...env, ...overrides, PATH: `${join(root, "bin")}:${env.PATH}` },
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("local core tests stay available without enabling optional products", () => {
  const result = runProfile({ tier: "bundle", features: ["voice"] }, ["--filter", "DaemonTests"]);
  expect(result.status).toBe(0);
  const run = JSON.parse(result.stdout);
  expect(run.env.HUDSONKIT_WITH_VOICE).toBe("0");
  expect(run.env.LATTICES_BUNDLE).toBe("0");
  expect(run.args).not.toContain("--force-resolved-versions");
  expect(run.args.slice(-2)).toEqual(["--filter", "DaemonTests"]);
});

test("release validation follows the manifest with pinned dependencies and no live probes", () => {
  const result = runProfile({ tier: "bundle", features: ["voice"] }, ["--release-profile"], {
    HUDSONKIT_WITH_VOICE: "0", LATTICES_BUNDLE: "0", LATTICES_HUDSON_SOURCE: "path",
    LATTICES_HUDSON_PATH: "/developer/hudson", LATTICES_VOX_SOURCE: "/developer/vox",
    HUDSON_VOX_PATH: "/developer/vox", HUDSON_VOX_GIT_BRANCH: "work-in-progress",
    HUDSON_VOX_GIT_URL: "https://example.invalid/vox.git", HUDSON_VOX_GIT_REVISION: "unreviewed",
    HUDSON_VOX_PACKAGE: "other", LONG_RENDER_DIR: "/tmp/probe", MACHINES_RENDER_DIR: "/tmp/probe",
    OVERVIEW_RENDER_DIR: "/tmp/probe",
  });
  expect(result.status).toBe(0);
  const run = JSON.parse(result.stdout);
  expect(run.env).toEqual({
    HUDSONKIT_WITH_VOICE: "1", LATTICES_BUNDLE: "1",
    LATTICES_HUDSON_SOURCE: "git", HUDSON_VOX_SOURCE: "git",
  });
  expect(run.args).toContain("--force-resolved-versions");
  expect(run.args.slice(-3)).toEqual(["--configuration", "release", "--force-resolved-versions"]);
  expect(run.args).toContain("Stage(Drag|Join|Tile)Tests");
  expect(run.args).not.toContain("--release-profile");
});

test("the release workflow's free-tier override keeps voice and excludes bundle sources", () => {
  const result = runProfile({ tier: "bundle", features: ["voice"] }, ["--release-profile"], { LATTICES_TIER: "free" });
  expect(result.status).toBe(0);
  const run = JSON.parse(result.stdout);
  expect(run.env.HUDSONKIT_WITH_VOICE).toBe("1");
  expect(run.env.LATTICES_BUNDLE).toBe("0");
});

test("removing a manifest feature removes it from release validation", () => {
  const result = runProfile({ tier: "free", features: [] }, ["--release-profile"], {
    HUDSONKIT_WITH_VOICE: "1", LATTICES_BUNDLE: "1",
  });
  expect(result.status).toBe(0);
  const run = JSON.parse(result.stdout);
  expect(run.env.HUDSONKIT_WITH_VOICE).toBe("0");
  expect(run.env.LATTICES_BUNDLE).toBe("0");
});

test("an invalid manifest stops release validation before invoking Swift", () => {
  const result = runProfile({ features: ["typo"] }, ["--release-profile"]);
  expect(result.status).not.toBe(0);
  expect(result.stdout).toBe("");
  expect(result.stderr).toContain('unknown build feature "typo"');
});
