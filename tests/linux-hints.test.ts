import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { linuxHintPack } from "../bin/cli/hints.ts";

const cli = fileURLToPath(new URL("../bin/lattices.ts", import.meta.url));
const personalKeys = (bindings: string) => linuxHintPack(bindings).groups.find(group => group.id === "personal");

test("personal hints require both space actions and ignore commented or unrelated bindings", () => {
  const left = 'o.bind("CTRL + LEFT", "Previous space", hl.dsp.focus({ workspace = "e-1" }))';
  const right = 'o.bind("CTRL + RIGHT", "Next space", hl.dsp.focus({ workspace = "e+1" }))';
  expect(personalKeys(`${left}\n${right}`)?.hints).toHaveLength(1);
  expect(personalKeys(`${left}\n-- ${right}`)).toBeUndefined();
  expect(personalKeys(`--[[\n${left}\n${right}\n]]`)).toBeUndefined();
  expect(personalKeys('o.bind("CTRL + LEFT", "Something else", "echo e-1")')).toBeUndefined();
});

test("hints JSON works without a desktop or daemon and reads the chosen XDG config", () => {
  const directory = mkdtempSync(join(tmpdir(), "lattices-hints-"));
  try {
    mkdirSync(join(directory, "hypr"));
    writeFileSync(join(directory, "hypr/bindings.lua"), 'o.bind("SUPER + CTRL + ALT + Home", "Cursor home", "lattices-host mouse-home")\n');
    const result = spawnSync(process.execPath, [cli, "hints", "--json"], { encoding: "utf8", env: { ...process.env, XDG_CONFIG_HOME: directory, LATTICES_DAEMON_PORT: "1" } });
    expect(result.status).toBe(0);
    const pack = JSON.parse(result.stdout);
    expect(pack.groups.find((group: { id: string }) => group.id === "personal").hints).toHaveLength(1);
    expect(result.stderr).toBe("");
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

(process.platform === "linux" ? test : test.skip)("Linux app commands select the page, reuse the app, and detach a new instance", () => {
  const directory = mkdtempSync(join(tmpdir(), "lattices-launch-"));
  try {
    const receipt = join(directory, "argv.jsonl");
    const quickshell = join(directory, "quickshell");
    writeFileSync(quickshell, `#!${process.execPath}\nimport { appendFileSync } from 'node:fs';\nappendFileSync(process.env.HINT_TEST_RECEIPT, JSON.stringify(process.argv.slice(2)) + '\\n');\nprocess.exit(process.argv[2] === 'ipc' ? Number(process.env.HINT_TEST_IPC_STATUS) : 0);\n`, { mode: 0o755 });
    const env = { ...process.env, PATH: directory + ":" + process.env.PATH, HINT_TEST_RECEIPT: receipt, HINT_TEST_IPC_STATUS: "0" };
    const reuse = spawnSync(process.execPath, [cli, "hints", "--open"], { env, encoding: "utf8" });
    expect(reuse.status).toBe(0);
    const calls = readFileSync(receipt, "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(calls).toHaveLength(1);
    expect(calls[0].slice(-4)).toEqual(["call", "lattices", "showPage", "Hints"]);

    for (const [command, page] of [["mission", "Mission"], ["console", "Console"]]) {
      writeFileSync(receipt, "");
      const selected = spawnSync(process.execPath, [cli, "app", command], { env, encoding: "utf8" });
      expect(selected.status).toBe(0);
      expect(JSON.parse(readFileSync(receipt, "utf8").trim()).slice(-4)).toEqual(["call", "lattices", "showPage", page]);
    }

    writeFileSync(receipt, "");
    const launch = spawnSync(process.execPath, [cli, "app"], { env: { ...env, HINT_TEST_IPC_STATUS: "255" }, encoding: "utf8" });
    expect(launch.status).toBe(0);
    const launches = readFileSync(receipt, "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(launches).toHaveLength(2);
    expect(launches[0].at(-1)).toBe("Home");
    expect(launches[1]).toContain("--daemonize");
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
