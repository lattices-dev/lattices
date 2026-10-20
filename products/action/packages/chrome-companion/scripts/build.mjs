import { cp, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = new URL("..", import.meta.url);
const rootPath = fileURLToPath(root);
const distPath = join(rootPath, "dist");

await rm(distPath, { recursive: true, force: true });
await mkdir(distPath, { recursive: true });

const result = await Bun.build({
  entrypoints: [
    join(rootPath, "src/bridge-page.ts"),
    join(rootPath, "src/service-worker.ts"),
    join(rootPath, "src/content-script.ts")
  ],
  outdir: distPath,
  target: "browser",
  format: "esm",
  sourcemap: "external"
});

if (!result.success) {
  for (const log of result.logs) {
    console.error(log);
  }
  process.exit(1);
}

await cp(join(rootPath, "manifest.json"), join(distPath, "manifest.json"));
await cp(join(rootPath, "bridge.html"), join(distPath, "bridge.html"));
