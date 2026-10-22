import type { Toolset } from "./types.ts";

/**
 * Every toolset the lattices MCP can serve. Toolsets are loaded lazily so that
 * `lats mcp --toolsets browser` does not pay the import cost of the ones it
 * was not asked for -- and, more importantly, so a toolset that owns a resource
 * never gets a chance to touch it when it is switched off.
 */
export const TOOLSET_LOADERS: Record<string, () => Promise<Toolset>> = {
  browser: async () => (await import("./toolsets/browser/index.ts")).browserToolset,
  hosts: async () => (await import("./toolsets/hosts/index.ts")).hostsToolset,
  windows: async () => (await import("./toolsets/windows/index.ts")).windowsToolset,
};

export const TOOLSET_NAMES = Object.keys(TOOLSET_LOADERS);

/**
 * Resolve a `--toolsets` selection. An unknown name is an error rather than a
 * silent no-op: a typo that quietly yields a server with no tools reads exactly
 * like the outage this whole design exists to prevent.
 */
export async function loadToolsets(selection?: readonly string[]): Promise<Toolset[]> {
  const names = selection?.length ? selection : TOOLSET_NAMES;
  const unknown = names.filter((name) => !(name in TOOLSET_LOADERS));
  if (unknown.length > 0) {
    throw new Error(
      `Unknown toolset${unknown.length > 1 ? "s" : ""}: ${unknown.join(", ")}. Available: ${TOOLSET_NAMES.join(", ")}.`,
    );
  }
  return await Promise.all(names.map((name) => TOOLSET_LOADERS[name]!()));
}
