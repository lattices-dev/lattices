import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { actionAppCandidates, findActionApp, isActionApp } from "./locate.js";

function fakeApp(dir: string, name = "Action.app"): string {
  const app = join(dir, name);
  mkdirSync(join(app, "Contents/MacOS"), { recursive: true });
  writeFileSync(join(app, "Contents/MacOS/Action"), "#!/bin/sh\n");
  chmodSync(join(app, "Contents/MacOS/Action"), 0o755);
  return app;
}

const previous = process.env.ACTION_APP;
const dirs: string[] = [];
afterEach(() => {
  if (previous === undefined) delete process.env.ACTION_APP; else process.env.ACTION_APP = previous;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("findActionApp", () => {
  test("an explicit path wins over ACTION_APP", () => {
    const dir = mkdtempSync(join(tmpdir(), "locate-")); dirs.push(dir);
    const explicit = fakeApp(dir, "Explicit.app");
    process.env.ACTION_APP = fakeApp(dir, "Env.app");
    expect(findActionApp(explicit, { running: false })).toBe(explicit);
    expect(findActionApp(undefined, { running: false })).toBe(process.env.ACTION_APP);
  });

  test("a bundle without an executable Action is not an app", () => {
    const dir = mkdtempSync(join(tmpdir(), "locate-")); dirs.push(dir);
    mkdirSync(join(dir, "Empty.app/Contents"), { recursive: true });
    expect(isActionApp(join(dir, "Empty.app"))).toBe(false);
  });

  test("candidates are configured, then standard, and never a Spotlight guess", () => {
    process.env.ACTION_APP = "/tmp/env/Action.app";
    const candidates = actionAppCandidates("/tmp/explicit/Action.app", { running: false });
    expect(candidates[0]).toBe("/tmp/explicit/Action.app");
    expect(candidates[1]).toBe("/tmp/env/Action.app");
    expect(candidates[2]).toBe("/Applications/Action.app");
    expect(candidates).toHaveLength(4);
  });
});
