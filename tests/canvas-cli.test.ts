import { expect, test } from "bun:test";
import { canvasCommand } from "../bin/cli/canvas.ts";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

test("Canvas prefers its canonical executable and preserves arguments without shell interpolation", () => {
  const calls: unknown[] = [];
  const args = ["new", "$(do-not-run)", "--body", "A note with spaces"];
  expect(canvasCommand(args, {
    which: name => `/fixture/${name}`,
    execute: (program, forwarded) => { calls.push([program, forwarded]); },
  })).toBe(0);
  expect(calls).toEqual([["/fixture/canvas", args]]);
});

test("Canvas forwards to an existing Blink CLI and preserves its exit status", () => {
  const resolved: string[] = [];
  expect(canvasCommand(["ls"], {
    which: name => { resolved.push(name); return name === "blink" ? "/fixture/blink" : null; },
    execute: (program, args) => { expect(program).toBe("/fixture/blink"); expect(args).toEqual(["ls"]); throw { status: 7 }; },
  })).toBe(7);
  expect(resolved).toEqual(["canvas", "blink"]);
});

test("remote selection and missing CLI fail before any local action", () => {
  let executed = false;
  const messages: string[] = [];
  expect(canvasCommand(["new", "note"], {
    remoteHost: "other-host", which: () => { throw new Error("Must not resolve locally"); },
    execute: () => { executed = true; }, report: message => messages.push(message),
  })).toBe(1);
  expect(canvasCommand([], {
    which: () => null, execute: () => { executed = true; }, report: message => messages.push(message),
  })).toBe(1);
  expect(executed).toBe(false);
  expect(messages[0]).toContain("local-only");
  expect(messages[1]).toContain("@arach/blink");
});

test("lats canvas and lats blink reach the installed CLI, while remote flags remain local-safe", () => {
  const root = mkdtempSync(join(tmpdir(), "canvas-cli-"));
  try {
    writeFileSync(join(root, "canvas"), '#!/bin/sh\nprintf "forwarded:%s\\n" "$@"\n', { mode: 0o700 });
    const cli = resolve(import.meta.dir, "../bin/lattices.ts");
    const env = { ...process.env, PATH: `${root}:${process.env.PATH}`, LATTICES_DAEMON_HOST: "" };
    for (const name of ["canvas", "blink"]) {
      const result = Bun.spawnSync([process.execPath, cli, name, "ls", "--json"], { env });
      expect(result.exitCode).toBe(0);
      expect(result.stdout.toString()).toContain("forwarded:ls\nforwarded:--json");
    }
    const remote = Bun.spawnSync([process.execPath, cli, "--host", "other-host", "canvas", "new", "note"], { env });
    expect(remote.exitCode).toBe(1);
    expect(remote.stdout.toString()).not.toContain("forwarded:");
    expect(remote.stderr.toString()).toContain("local-only");
  } finally { rmSync(root, { recursive: true, force: true }); }
});
