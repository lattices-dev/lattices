import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { resolveBuildEnv } from "./lattices-build-env";

export function sourceDigest(root: string, buildEnv: Record<string, string>): string {
  const paths = execFileSync("git", [
    "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
    "apps/mac/Sources", "apps/mac/Resources", "apps/mac/Package.swift", "apps/mac/Package.resolved",
    "apps/mac/Info.plist", "apps/mac/Lattices.entitlements", "apps/mac/build.json", "swift",
    "bin", "tools/release", "package.json", "bun.lock", "assets/AppIcon.icns", "assets/Assets.car", "docs/assistant-knowledge.md",
  ], { cwd: root, encoding: "utf8" }).split("\0").filter(Boolean);
  const hash = createHash("sha256");
  hash.update("lattices-repository-build-inputs-v1\0");
  hash.update(JSON.stringify(Object.entries(buildEnv).sort()));
  for (const path of [...new Set(paths)].sort()) {
    hash.update(`\0${path}\0`);
    const absolutePath = resolve(root, path);
    hash.update(existsSync(absolutePath) ? createHash("sha256").update(readFileSync(absolutePath)).digest("hex") : "missing");
  }
  return hash.digest("hex");
}

export function readBuildMetadata(root: string, buildEnv = resolveBuildEnv()) {
  return {
    revision: execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim(),
    timestamp: new Date().toISOString(),
    sourceDigest: sourceDigest(root, buildEnv),
  };
}

if (import.meta.main) {
  const metadata = readBuildMetadata(resolve(import.meta.dir, ".."));
  if (process.argv[2] === "digest") {
    console.log(metadata.sourceDigest);
  } else {
    for (const [key, value] of Object.entries(metadata)) {
      console.log(`export LATTICES_BUILD_${key.toUpperCase()}=${JSON.stringify(value)}`);
    }
  }
}
