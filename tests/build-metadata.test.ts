import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sourceDigest } from "../bin/lattices-build-metadata";

test("build digest binds dirty and untracked source, resources, and feature flags, not output", () => {
  const root = mkdtempSync(join(tmpdir(), "lattices-build-metadata-"));
  try {
    execFileSync("git", ["init", "--quiet", root]);
    mkdirSync(join(root, "apps/mac/Sources"), { recursive: true });
    mkdirSync(join(root, "apps/mac/Resources/Editor"), { recursive: true });
    mkdirSync(join(root, "apps/mac/Lattices.app/Contents"), { recursive: true });
    const source = join(root, "apps/mac/Sources/Main.swift");
    writeFileSync(source, "initial");
    execFileSync("git", ["add", "."], { cwd: root });
    const original = sourceDigest(root, { LATTICES_BUNDLE: "0" });
    expect(original).toMatch(/^[a-f0-9]{64}$/);
    expect(sourceDigest(root, { LATTICES_BUNDLE: "0" })).toBe(original);
    writeFileSync(join(root, "apps/mac/Lattices.app/Contents/Info.plist"), "generated");
    expect(sourceDigest(root, { LATTICES_BUNDLE: "0" })).toBe(original);
    expect(sourceDigest(root, { LATTICES_BUNDLE: "1" })).not.toBe(original);
    writeFileSync(source, "changed");
    expect(sourceDigest(root, { LATTICES_BUNDLE: "0" })).not.toBe(original);
    writeFileSync(source, "initial");
    writeFileSync(join(root, "apps/mac/Resources/Editor/editor.js"), "untracked resource");
    expect(sourceDigest(root, { LATTICES_BUNDLE: "0" })).not.toBe(original);
    rmSync(join(root, "apps/mac/Resources/Editor/editor.js"));
    rmSync(source);
    expect(sourceDigest(root, { LATTICES_BUNDLE: "0" })).not.toBe(original);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
