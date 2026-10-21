import type { NextConfig } from "next";
import path from "node:path";
import { fileURLToPath } from "node:url";

// This app lives at ~/dev/lattices/design/studio but consumes `studio` and
// `hudsonkit` from sibling repos (~/dev/studio, ~/dev/hudson) via the studio
// bun workspace. Pin Turbopack's root to the common ancestor (~/dev) so it can
// resolve the symlinked packages instead of mis-inferring the workspace root.
const here = path.dirname(fileURLToPath(import.meta.url));

const nextConfig: NextConfig = {
  turbopack: { root: path.resolve(here, "../../..") },
  transpilePackages: ["hudsonkit", "studio"],
  // Next 16 serves dev chunks and HMR to localhost only. Without this, a page
  // opened at 127.0.0.1:3050 renders but never hydrates, so no control works.
  allowedDevOrigins: ["127.0.0.1"],
};

export default nextConfig;
