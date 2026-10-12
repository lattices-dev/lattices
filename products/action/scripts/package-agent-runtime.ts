#!/usr/bin/env bun
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { orchestrationDigest } from "../packages/runtime/src/capabilities.ts";

// Produce an immutable candidate; never install, rebuild, or change host quarantine.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const { values } = parseArgs({ options: {
  app: { type: "string" }, output: { type: "string" }, "instructions-root": { type: "string" },
}, strict: true, allowPositionals: false });
if (!values.app || !values.output || !values["instructions-root"]) {
  throw new Error("Usage: bun scripts/package-agent-runtime.ts --app /path/Action.app --output /new/runtime --instructions-root /path/to/lattices-docs-checkout");
}
const app = resolve(values.app);
const output = resolve(values.output);
const instructionsRoot = resolve(values["instructions-root"]);
if (existsSync(output) || existsSync(`${output}.tar.gz`)) throw new Error("Candidate output already exists; choose a new path to preserve rollback.");
const env = { ...process.env, ACTION_DIST_DIR: dirname(app) };
execFileSync(join(root, "native/engine/scripts/verify-app.sh"), [], { env, stdio: ["ignore", "ignore", "pipe"] });
const manifest = JSON.parse(readFileSync(join(app, "Contents/Resources/build-provenance.json"), "utf8"));
const digest = orchestrationDigest(root);
if (manifest.build?.orchestrationSourceDigest !== digest) throw new Error("Signed app/MCP source mismatch. Build the matching app on the development host before packaging.");

const instructions = [
  ["products/action/docs/agent-layer.md", "docs/agent-layer.md"],
  ["products/action/docs/native-runtime.md", "docs/native-runtime.md"],
  ["skills/action/SKILL.md", "skills/action/SKILL.md"],
] as const;
for (const [source] of instructions) {
  if (!existsSync(join(instructionsRoot, source))) throw new Error(`Missing instruction source: ${source}`);
}
mkdirSync(dirname(output), { recursive: true });
const staging = mkdtempSync(join(dirname(output), ".action-runtime-"));
const stagedActionRoot = join(staging, "products/action");
const archive = `${staging}.tar.gz`;
const sha256 = (file: string) => createHash("sha256").update(readFileSync(file)).digest("hex");
try {
  mkdirSync(stagedActionRoot, { recursive: true });
  mkdirSync(join(staging, "bin"), { recursive: true });
  const pairingSource = resolve(root, "../../bin/host-pairing.ts");
  const pairingTarget = join(staging, "bin/host-pairing.ts");
  cpSync(pairingSource, pairingTarget);
  if (sha256(pairingTarget) !== sha256(pairingSource)) throw new Error("Staged host-pairing dependency differs from the canonical source.");
  for (const file of ["package.json", "bun.lock", "tsconfig.json"]) cpSync(join(root, file), join(stagedActionRoot, file));
  // Copy exact fingerprint inputs and source assets, never sessions, credentials or build output.
  cpSync(join(root, "packages"), join(stagedActionRoot, "packages"), { recursive: true, filter: (source) => {
    const name = source.split("/").at(-1)!;
    return name !== "node_modules" && name !== "dist" && !name.startsWith(".");
  } });
  for (const directory of ["scenarios", "themes"]) cpSync(join(root, directory), join(stagedActionRoot, directory), { recursive: true });
  mkdirSync(join(stagedActionRoot, "native/engine/scripts"), { recursive: true });
  cpSync(join(root, "native/engine/scripts/run-app-host.sh"), join(stagedActionRoot, "native/engine/scripts/run-app-host.sh"));
  mkdirSync(join(stagedActionRoot, "native/dist"), { recursive: true });
  execFileSync("/usr/bin/ditto", [app, join(stagedActionRoot, "native/dist/Action.app")]);
  const instructionHashes: Record<string, string> = {};
  for (const [source, destination] of instructions) {
    const target = join(stagedActionRoot, destination);
    mkdirSync(dirname(target), { recursive: true });
    cpSync(join(instructionsRoot, source), target);
    instructionHashes[destination] = sha256(target);
  }
  execFileSync("bun", ["install", "--production", "--frozen-lockfile", "--ignore-scripts"], { cwd: stagedActionRoot, stdio: ["ignore", "pipe", "pipe"] });
  if (orchestrationDigest(stagedActionRoot) !== digest) throw new Error("Staged orchestration differs from the signed app's recorded inputs.");
  const stagedEnv = { ...process.env, ACTION_ROOT: stagedActionRoot, ACTION_DIST_DIR: join(stagedActionRoot, "native/dist"), ACTION_NATIVE_HOST: join(stagedActionRoot, "native/engine/scripts/run-app-host.sh") };
  execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", join(stagedActionRoot, "native/dist/Action.app")], { stdio: "pipe" });
  const capabilities = JSON.parse(execFileSync("bun", ["packages/cli/src/main.ts", "capabilities"], { cwd: stagedActionRoot, env: stagedEnv, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
  if (capabilities.runtimeParity.state !== "matched-source-digest") throw new Error("Staged CLI discovery did not confirm the matching app/runtime.");
  const provenance = {
    schemaVersion: 1, product: "Action", createdAt: new Date().toISOString(),
    orchestrationSourceDigest: digest, nativeBuild: manifest.build,
    actionRoot: "products/action", sourceDependencies: { "bin/host-pairing.ts": sha256(pairingTarget) },
    nativeExecutableSha256: sha256(join(stagedActionRoot, "native/dist/Action.app/Contents/MacOS/Action")),
    instructions: instructionHashes, bunVersion: execFileSync("bun", ["--version"], { encoding: "utf8" }).trim(),
    desktopIsolationAcceptance: { state: "not-certified", note: "A matching artifact pair does not certify a host/display configuration. Preserve host quarantine and rollback; reconnect MCP and validate acceptance separately." },
  };
  writeFileSync(join(staging, "runtime-provenance.json"), JSON.stringify(provenance, null, 2) + "\n");
  writeFileSync(join(stagedActionRoot, "runtime-provenance.json"), JSON.stringify(provenance, null, 2) + "\n");
  writeFileSync(join(staging, "README-runtime.md"), "# Action agent runtime candidate\n\nSet `ACTION_ROOT=<bundle>/products/action` and configure MCP as `bun <ACTION_ROOT>/packages/mcp/src/index.ts`. Keep the bundle's `bin/` directory alongside `products/`; the runtime imports its canonical host-pairing dependency from there. Run the CLI's `capabilities` and fresh MCP `capabilities` / `tools/list`; reconnect after updates. Native primitives use the bundled signed app. This candidate does not certify desktop isolation. Preserve the host's quarantine and the previous runtime for rollback. See `<ACTION_ROOT>/docs/agent-layer.md` before opening.\n");
  execFileSync("/usr/bin/tar", ["-czf", archive, "-C", staging, ...readdirSync(staging).sort()]);
  renameSync(staging, output);
  renameSync(archive, `${output}.tar.gz`);
  console.log(JSON.stringify({ ok: true, runtime: join(output, "products/action"), bundle: output, archive: `${output}.tar.gz`, archiveSha256: sha256(`${output}.tar.gz`), provenance }, null, 2));
} catch (error) {
  rmSync(staging, { recursive: true, force: true });
  rmSync(archive, { force: true });
  throw error;
}
