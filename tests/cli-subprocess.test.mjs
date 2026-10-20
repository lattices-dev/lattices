import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";

// Load the production function without dispatching the CLI or touching installed apps.
function loadFunction(file, name, globals) {
  const source = fs.readFileSync(new URL(`../bin/${file}`, import.meta.url), "utf8");
  const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const declaration = ast.statements.find((node) =>
    ts.isFunctionDeclaration(node) && node.name?.text === name
  );
  assert.ok(declaration, `Missing ${name}`);
  const { outputText } = ts.transpileModule(declaration.getText(ast), {
    compilerOptions: { target: ts.ScriptTarget.ESNext },
  });
  return runInNewContext(`${outputText}\n${name}`, {
    ...fs, join, resolve, execFileSync, spawnSync, ...globals,
  });
}

function fixture(t) {
  const root = fs.mkdtempSync(join(tmpdir(), "lattices-subprocess-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const directory = join(root, "owner's $(touch SHOULD_NOT_EXIST) `echo literal` workspace");
  fs.mkdirSync(directory);
  return { root, directory };
}

test("Action reads a version from an app path containing shell syntax", {
  skip: process.platform !== "darwin" ? "requires macOS PlistBuddy" : false,
}, (t) => {
  const { directory } = fixture(t);
  const app = join(directory, "Action.app");
  fs.mkdirSync(join(app, "Contents"), { recursive: true });
  fs.writeFileSync(join(app, "Contents/Info.plist"), `<?xml version="1.0"?>
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.2.3</string></dict></plist>`);
  const version = loadFunction("lattices-action.ts", "installedVersion", {});
  assert.equal(version(app), "1.2.3");
});

for (const [file, name, appName] of [
  ["lattices-action.ts", "installAppFromDmg", "Action.app"],
  ["lattices-app.ts", "installBundleFromDmg", "Lattices.app"],
]) {
  test(`${appName} install preserves literal paths and detaches the disk image`, (t) => {
    const { directory } = fixture(t);
    const destination = join(directory, appName);
    const dmg = join(directory, "download's image.dmg");
    const calls = [];
    const install = loadFunction(file, name, {
      tmpdir: () => directory,
      INSTALL_PATH: destination,
      bundlePath: destination,
      ACTION_APP_NAME: appName,
      execFileSync(command, args, options) {
        if (command !== "hdiutil") return execFileSync(command, args, options);
        calls.push([...args]);
        if (args[0] === "attach") {
          const mountedApp = join(args[4], appName);
          fs.mkdirSync(mountedApp);
          fs.writeFileSync(join(mountedApp, "payload"), "signed app fixture");
        }
        return Buffer.alloc(0);
      },
    });
    install(dmg);
    assert.equal(fs.readFileSync(join(destination, "payload"), "utf8"), "signed app fixture");
    assert.deepEqual(calls[0], ["attach", "-nobrowse", "-readonly", "-mountpoint", calls[0][4], dmg]);
    assert.deepEqual(calls[1], ["detach", calls[0][4], "-quiet"]);
    assert.equal(fs.existsSync(calls[0][4]), false);
  });
}

test("codesign metadata remains readable from stderr and fails closed", () => {
  for (const [status, stderr, expected] of [
    [0, "TeamIdentifier=TEAM123\n", "TEAM123"],
    [0, "TeamIdentifier=not set\n", null],
    [1, "TeamIdentifier=TEAM123\n", null],
  ]) {
    const bundlePath = "/tmp/owner's workspace/Lattices.app";
    const team = loadFunction("lattices-app.ts", "bundleTeamIdentifier", {
      bundlePath,
      spawnSync(command, args) {
        assert.equal(command, "codesign");
        assert.deepEqual([...args], ["-dv", bundlePath]);
        return { status, stdout: "", stderr };
      },
    });
    assert.equal(team(), expected);
  }
});

test("tmux receives the target as one literal argument for attach and switch", () => {
  const target = 'workspace " $(touch SHOULD_NOT_EXIST)';
  for (const inside of [false, true]) {
    let received;
    const attach = loadFunction("lattices.ts", "attach", {
      isInsideTmux: () => inside,
      execFileSync(command, args) { received = [command, ...args]; },
    });
    attach(target);
    assert.deepEqual(received, ["tmux", inside ? "switch-client" : "attach", "-t", target]);
  }
});

test("gateway dispatch keeps the Bun executable found by the GUI launcher", (t) => {
  const found = spawnSync("which", ["bun"], { encoding: "utf8" });
  if (found.status !== 0) { t.skip("Bun is unavailable"); return; }
  const result = spawnSync(fs.realpathSync(new URL("../bin/lattices", import.meta.url)), ["gateway", "--help"], {
    encoding: "utf8", timeout: 10_000,
    env: { ...process.env, PATH: "/usr/bin:/bin", LATTICES_BUN_BIN: found.stdout.trim() },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /gateway.*tailnet/s);
});
