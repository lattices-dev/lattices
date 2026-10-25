import type { NextConfig } from "next";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Studio is pinned to a complete Git revision. Hudson remains an explicit
// sibling workspace at ~/dev/hudson; include the common ancestor (~/dev) so
// Turbopack can resolve that package's source through its workspace symlink.
const here = path.dirname(fileURLToPath(import.meta.url));

const nextConfig: NextConfig = {
  turbopack: { root: path.resolve(here, "../../..") },
  transpilePackages: ["hudsonkit", "studio"],
  // Next 16 serves dev chunks and HMR to localhost only. Without this, a page
  // opened at 127.0.0.1:3050 renders but never hydrates, so no control works.
  allowedDevOrigins: ["127.0.0.1"],
};

export default nextConfig;
