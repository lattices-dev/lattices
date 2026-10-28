import { expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const repoBin = resolve(import.meta.dir, "../bin");
const macTest = process.platform === "darwin" ? test : test.skip;

function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "lattices-app-launch-")));
  const runnerBin = join(root, "inert-runners");
  mkdirSync(runnerBin);
  // The CLI dispatcher runs normally, but its app helper runner only records
  // arguments. These tests cannot start, stop, build, or install an app.
  writeFileSync(join(runnerBin, "bun"), '#!/bin/sh\nprintf "FIXTURE_RELEASE\\n"\nprintf "ARG:%s\\n" "$@"\n', { mode: 0o755 });

  function installation(name: string, source: boolean) {
    const owner = join(root, name);
    const bin = join(owner, "bin");
    mkdirSync(bin, { recursive: true });
    // Use the actual entrypoint and actual imported CLI modules. Only the two
    // helper launch targets are inert fixtures; no implementation is extracted.
    for (const entry of readdirSync(repoBin)) {
      if (["lattices", "lattices.ts", "lattices-app.ts", "lattices-dev"].includes(entry)) continue;
      symlinkSync(join(repoBin, entry), join(bin, entry));
    }
    for (const entry of ["lattices", "lattices.ts"]) copyFileSync(join(repoBin, entry), join(bin, entry));
    writeFileSync(join(bin, "lattices-app.ts"), "// Intentionally inert app-helper fixture.\n");
    writeFileSync(join(bin, "lattices-dev"), '#!/bin/sh\nprintf "FIXTURE_DEV:%s\\n" "$0"\nprintf "ARG:%s\\n" "$@"\n', { mode: 0o755 });
    writeFileSync(join(owner, "package.json"), JSON.stringify({ name: "@lattices/lattices", version: "0.15.3", type: "module" }));
    if (source) {
      mkdirSync(join(owner, "apps/mac"), { recursive: true });
      writeFileSync(join(owner, "apps/mac/Package.swift"), "// Source-checkout fixture.\n");
    }
    return owner;
  }

  function run(entry: string, cwd: string, args: string[], wrapper = false) {
    const result = Bun.spawnSync(wrapper ? [entry, ...args] : [process.execPath, entry, ...args], {
      cwd,
      env: {
        ...process.env,
        PATH: `${runnerBin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
        LATTICES_BUN_BIN: process.execPath,
        LATTICES_DAEMON_HOST: "",
      },
      timeout: 15_000,
    });
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    return result.stdout.toString();
  }

  return { root, installation, run, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

macTest("installed app commands stay with their package when cwd is a source checkout", () => {
  const f = fixture();
  try {
    const installed = f.installation("installed", false);
    const checkout = f.installation("dev-checkout", true);
    for (const command of [undefined, "start", "build", "restart", "quit", "stop", "install", "uninstall", "login", "startup", "status"]) {
      const args = command ? ["app", command, "--fixture"] : ["app", "--fixture"];
      const output = f.run(join(installed, "bin/lattices.ts"), checkout, args);
      expect(output).toContain(`FIXTURE_RELEASE\nARG:${installed}/bin/lattices-app.ts\n`);
      expect(output).toContain("ARG:--fixture\n");
      expect(output).not.toContain("FIXTURE_DEV:");
    }
  } finally { f.cleanup(); }
});

macTest("a source CLI owns its dev bundle in its checkout and from other directories", () => {
  const f = fixture();
  try {
    const owner = f.installation("source-owner", true);
    const other = f.installation("other-checkout", true);
    for (const cwd of [owner, other, f.root]) {
      const output = f.run(join(owner, "bin/lattices.ts"), cwd, ["app", "--fixture"]);
      expect(output).toContain(`FIXTURE_DEV:${owner}/bin/lattices-dev\nARG:launch\nARG:--fixture\n`);
      expect(output).not.toContain("FIXTURE_RELEASE");
    }
  } finally { f.cleanup(); }
});

macTest("global aliases and entrypoint symlinks retain their canonical CLI owner", () => {
  const f = fixture();
  try {
    const checkout = f.installation("cwd-checkout", true);
    for (const source of [false, true]) {
      const owner = f.installation(source ? "linked-source" : "linked-installed", source);
      const wrapper = join(f.root, source ? "source-lats" : "installed-lats");
      symlinkSync(join(owner, "bin/lattices"), wrapper);
      const entrypoint = join(f.root, source ? "source-entry.ts" : "installed-entry.ts");
      symlinkSync(join(owner, "bin/lattices.ts"), entrypoint);
      for (const [entry, isWrapper] of [[wrapper, true], [entrypoint, false]] as const) {
        const output = f.run(entry, checkout, ["app", "status"], isWrapper);
        expect(output).toContain(source
          ? `FIXTURE_DEV:${owner}/bin/lattices-dev\nARG:status\n`
          : `FIXTURE_RELEASE\nARG:${owner}/bin/lattices-app.ts\nARG:status\n`);
      }
    }
  } finally { f.cleanup(); }
});

macTest("explicit dev commands continue to target the current source checkout", () => {
  const f = fixture();
  try {
    const installed = f.installation("installed", false);
    const checkout = f.installation("requested-checkout", true);
    const output = f.run(join(installed, "bin/lattices.ts"), checkout, ["dev", "restart", "--fixture"]);
    expect(output).toContain(`FIXTURE_DEV:${checkout}/bin/lattices-dev\nARG:restart\nARG:--fixture\n`);
    expect(output).not.toContain("FIXTURE_RELEASE");
  } finally { f.cleanup(); }
});
