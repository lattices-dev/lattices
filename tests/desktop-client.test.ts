import { expect, test } from "bun:test";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runtimeFiles } from "../apps/linux/install/runtime.ts";
import { daemonCallTo } from "../packages/desktop-client/daemon-client.ts";
import { daemonCallTo as compatibilityCall } from "../bin/daemon-client.ts";
import { signingKey } from "../packages/desktop-client/host-pairing.ts";
import { signingKey as compatibilitySigningKey } from "../bin/host-pairing.ts";
import { parseSpaceArgs } from "../bin/cli/spaces.ts";
import { parseEntry } from "../apps/linux/FlightDeckModel.mjs";
import { workspaceTarget } from "../packages/desktop-client/workspace-target.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));

test("published client entry points retain the shared transport and pairing implementation", () => {
  expect(compatibilityCall).toBe(daemonCallTo);
  expect(compatibilitySigningKey).toBe(signingKey);
});

test("CLI and app agree on workspace boundaries while retaining their command syntax", () => {
  for (const target of ["next", "prev", "previous", "1", "2147483647"]) {
    const workspace = workspaceTarget(target);
    expect(parseSpaceArgs([target, "--dry-run"]).workspace).toBe(workspace);
    expect(parseEntry("> space " + target + " --dry-run", [], [])).toMatchObject({
      kind: "rpc", method: "spaces.focus", params: { workspace, dryRun: true },
    });
  }
  for (const target of ["0", "-1", "01", "1.0", "1e2", "0x12", "2147483648", "constructor", "__proto__"]) {
    expect(workspaceTarget(target)).toBeNull();
    expect(() => parseSpaceArgs([target])).toThrow();
    expect(parseEntry("> space " + target, [], []).kind).toBe("error");
  }
});

test("copied runtime resolves shared CLI and QML modules without the checkout or dev dependencies", () => {
  const files = runtimeFiles(root);
  expect(files).toContain("packages/desktop-client/daemon-client.ts");
  expect(files).toContain("packages/host-linux/systemd/lattices-host.service");
  expect(files).toContain("apps/linux/integrations/omarchy/plugin/pen/PenService.qml");
  expect(files.some(file => /\/(node_modules|tests?|\.git)\//.test(file))).toBe(false);
  const copy = mkdtempSync(join(tmpdir(), "lats-client-runtime-"));
  try {
    for (const file of files) {
      mkdirSync(dirname(join(copy, file)), { recursive: true });
      cpSync(join(root, file), join(copy, file));
    }
    const run = (args: string[]) => Bun.spawnSync([process.execPath, ...args], {
      cwd: copy, env: { ...process.env, BUN_INSTALL_AUTO: "disable" }, stdout: "pipe", stderr: "pipe",
    });
    const cli = run(["bin/lattices.ts", "hints", "--json"]);
    expect(cli.stderr.toString()).toBe("");
    expect(cli.exitCode).toBe(0);
    expect(JSON.parse(cli.stdout.toString()).groups.length).toBeGreaterThan(0);
    const model = run(["-e", 'import { parseEntry } from "./apps/linux/FlightDeckModel.mjs"; console.log(JSON.stringify(parseEntry("> space next", [], [])))']);
    expect(model.exitCode).toBe(0);
    expect(JSON.parse(model.stdout.toString())).toMatchObject({ method: "spaces.focus", params: { workspace: "e+1" } });
    const installer = run(["apps/linux/install.ts", "--help"]);
    expect(installer.exitCode).toBe(0);
    expect(installer.stdout.toString()).toContain("Install Lattices for Linux");
    const manifest = JSON.parse(readFileSync(join(copy, "package.json"), "utf8"));
    expect(manifest.files).toContain("packages/desktop-client");
  } finally { rmSync(copy, { recursive: true, force: true }); }
});
