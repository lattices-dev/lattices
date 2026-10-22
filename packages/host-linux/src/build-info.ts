// Snapshot the running source revision once, not whenever describe is called.
// Bundles embed this same shape at build time and need neither .git nor git.
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
// The host ships as part of the lattices release, so it reports the repo's
// release version (root package.json), not the private workspace package's.
import { version as releaseVersion } from "../../../package.json";

export const VERSION: string = releaseVersion;
export interface BuildIdentity {
  version: string;
  commit: string | null;
  dirty: boolean | null;
}

const sourceRoot = fileURLToPath(new URL("../../../", import.meta.url));

export function sourceBuildIdentity(root = sourceRoot): BuildIdentity {
  const unknown: BuildIdentity = { version: VERSION, commit: null, dirty: null };
  // Never attribute a copied source/binary to an unrelated ancestor checkout.
  if (!existsSync(join(root, ".git"))) return unknown;
  const git = (...args: string[]) => {
    const result = spawnSync("git", ["-C", root, ...args], { encoding: "utf8", timeout: 2000 });
    return result.status === 0 ? result.stdout.trim() : null;
  };
  const commit = git("rev-parse", "--verify", "HEAD");
  if (!commit || !/^[0-9a-f]{40,64}$/.test(commit)) return unknown;
  const status = git("status", "--porcelain", "--untracked-files=normal", "--", "packages/host-linux", "package.json");
  return { version: VERSION, commit, dirty: status === null ? null : status.length > 0 };
}

// Replaced by scripts/build.ts. A raw source run uses the startup Git snapshot.
// Unknown fields stay null; no environment-derived/fabricated commit fallback.
declare const LATTICES_HOST_BUILD_IDENTITY: BuildIdentity | undefined;
export const BUILD_IDENTITY: Readonly<BuildIdentity> = Object.freeze(
  typeof LATTICES_HOST_BUILD_IDENTITY === "undefined" ? sourceBuildIdentity() : LATTICES_HOST_BUILD_IDENTITY
);
