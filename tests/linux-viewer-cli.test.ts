import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

test("viewer commands use their own IPC route and hidden startup never activates the app", async () => {
  const directory = mkdtempSync(join(tmpdir(), "lats-viewer-cli-"));
  const log = join(directory, "calls");
  const qs = join(directory, "quickshell");
  writeFileSync(qs, '#!/bin/sh\nprintf "%s | viewer=%s\\n" "$*" "$LATTICES_LINUX_VIEWER" >> "$LATS_TEST_QS_LOG"\nif [ "$1" = ipc ] && [ "$LATS_TEST_QS_MISSING" = 1 ]; then exit 1; fi\nexit 0\n', { mode: 0o755 });
  const main = fileURLToPath(new URL("../apps/linux/main.ts", import.meta.url));
  const run = async (action: string, missing = false) => {
    writeFileSync(log, "");
    const child = Bun.spawn([process.execPath, main, "--detach", "--viewer", action], { stdout: "pipe", stderr: "pipe", env: { ...process.env, PATH: directory + ":" + process.env.PATH, LATS_TEST_QS_LOG: log, LATS_TEST_QS_MISSING: missing ? "1" : "0" } });
    const [code, error] = await Promise.all([child.exited, new Response(child.stderr).text()]);
    return { code, error, calls: readFileSync(log, "utf8") };
  };
  try {
    for (const action of ["show", "hide", "toggle"]) {
      const result = await run(action);
      expect(result.code).toBe(0); expect(result.calls).toContain("call lattices viewer " + (action === "show" ? "on" : action === "hide" ? "off" : action));
      expect(result.calls).not.toContain("showPage"); expect(result.calls).not.toContain("--daemonize");
    }
    const hidden = await run("hide", true);
    expect(hidden.code).toBe(0); expect(hidden.calls).not.toContain("--daemonize");
    const started = await run("show", true);
    expect(started.code).toBe(0); expect(started.calls).toContain("--daemonize | viewer=show");
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
