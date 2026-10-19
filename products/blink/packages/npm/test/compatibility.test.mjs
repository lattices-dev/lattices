import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync, chmodSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { assertNoDowngrade, BUNDLE_ID, installedApps, installMountedApp, mountedAppName, selectRelease, SIGNING_REQUIREMENT } from '../bin/canvas-app-support.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
function release(tag, name = tag.startsWith('canvas') ? 'Canvas' : 'Blink') {
  return { tag_name: tag, draft: false, prerelease: false, assets: [{ state: 'uploaded', size: 4096, name: `${name}.dmg`, browser_download_url: `https://github.com/arach/lattices/releases/download/${tag}/${name}.dmg` }] };
}
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'canvas-compat-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const directory = join(root, 'Applications'); mkdirSync(directory);
  const calls = [];
  const run = (cmd, args) => {
    calls.push([cmd, args]);
    if (cmd === 'plutil') return JSON.parse(readFileSync(args.at(-1), 'utf8'))[args[1]];
    if (cmd === 'ditto') cpSync(args[0], args[1], { recursive: true });
    return '';
  };
  function app(path, id = BUNDLE_ID, text = 'old', version = '2.2.0') {
    mkdirSync(join(path, 'Contents'), { recursive: true });
    writeFileSync(join(path, 'Contents', 'Info.plist'), JSON.stringify({ CFBundleIdentifier: id, CFBundleShortVersionString: version }));
    writeFileSync(join(path, 'Contents', 'payload'), text);
    return path;
  }
  return { root, directory, calls, run, app, expectedVersion: '2.2.0', mounted: app(join(root, 'mounted', 'Canvas.app'), BUNDLE_ID, 'new') };
}

test('stable exact product contracts choose SemVer and prefer Canvas on equal versions', () => {
  assert.equal(selectRelease([release('blink-v2.10.0'), release('canvas-v2.9.0')]).tag, 'blink-v2.10.0');
  assert.equal(selectRelease([release('blink-v2.2.0'), release('canvas-v2.2.0')]).tag, 'canvas-v2.2.0');
  const candidates = [release('canvas-v2.2.0'), release('canvas-v99.0.0')]; candidates[1].prerelease = true;
  assert.equal(selectRelease(candidates).tag, 'canvas-v2.2.0');
  assert.throws(() => selectRelease([release('canvas-v2.2.0', 'Blink'), release('canvas-v3.0.0-beta.1')]));
});

test('selector tolerates malformed URLs but rejects duplicate assets and foreign release URLs', () => {
  const good = release('canvas-v2.2.0'); good.assets[0].browser_download_url = good.assets[0].browser_download_url.replace('/arach/', '/lattices-dev/');
  const malformed = release('canvas-v5.0.0'); malformed.assets[0].browser_download_url = '%';
  const foreign = release('canvas-v6.0.0'); foreign.assets[0].browser_download_url = foreign.assets[0].browser_download_url.replace('/arach/', '/attacker/');
  const duplicate = release('canvas-v7.0.0'); duplicate.assets.push(duplicate.assets[0]);
  assert.equal(selectRelease([malformed, foreign, duplicate, good]).tag, good.tag_name);
});

test('selector rejects incomplete release flags, unsafe versions and invalid asset metadata', () => {
  const missing = release('canvas-v3.0.0'); delete missing.draft;
  const invalid = release('canvas-v4.0.0'); invalid.assets[0].size = -1;
  assert.throws(() => selectRelease([null, missing, invalid, release('canvas-v02.2.0'), release('canvas-v9007199254740992.0.0')]));
});

test('image accepts either one known app basename and rejects ambiguous images', t => {
  const f = fixture(t); const mount = dirname(f.mounted);
  assert.equal(mountedAppName(mount), 'Canvas.app');
  f.app(join(mount, 'Blink.app')); assert.throws(() => mountedAppName(mount), /exactly one/);
});

test('dangling destination links and mounted links are refused without changing targets', t => {
  const f = fixture(t);
  const destination = join(f.directory, 'Canvas.app');
  symlinkSync(join(f.root, 'not-created'), destination);
  assert.throws(() => installMountedApp({ ...f, appName: 'Canvas.app' }), /symlink/);
  assert.equal(f.calls.some(([cmd]) => cmd === 'ditto'), false);
  const mount = join(f.root, 'bad-mount'); mkdirSync(mount);
  symlinkSync(f.mounted, join(mount, 'Canvas.app'));
  assert.throws(() => mountedAppName(mount), /symlink/);
  assert.throws(() => installMountedApp({ ...f, mounted: join(mount, 'Canvas.app'), appName: 'Canvas.app' }), /symlink/);
});

test('existing Canvas is not downgraded to an older or same-version legacy release', t => {
  const f = fixture(t); const app = f.app(join(f.directory, 'Canvas.app'));
  assert.throws(() => assertNoDowngrade(selectRelease([release('blink-v2.2.0')]), [app], f.run), /downgrade/);
  assert.throws(() => assertNoDowngrade(selectRelease([release('canvas-v2.1.9')]), [app], f.run), /downgrade/);
  assert.doesNotThrow(() => assertNoDowngrade(selectRelease([release('canvas-v2.2.0')]), [app], f.run));
});

test('upgrade renames legacy app safely, preserves data, and requires original Developer ID', t => {
  const f = fixture(t); f.app(join(f.directory, 'Blink.app'));
  const data = join(f.root, 'notes.md'); writeFileSync(data, 'existing notes and foreign metadata');
  const result = installMountedApp({ ...f, appName: 'Canvas.app' });
  assert.equal(result, join(f.directory, 'Canvas.app'));
  assert.equal(readFileSync(join(result, 'Contents', 'payload'), 'utf8'), 'new');
  assert.equal(existsSync(join(f.directory, 'Blink.app')), false);
  assert.equal(readFileSync(data, 'utf8'), 'existing notes and foreign metadata');
  assert.deepEqual(installedApps([f.directory], f.run), [result]);
  assert.ok(f.calls.find(([cmd, args]) => cmd === 'codesign' && args.includes(SIGNING_REQUIREMENT)));
  const policy = JSON.parse(readFileSync(resolve(root, '../../../../tools/release/companion-signing.json'), 'utf8'));
  assert.ok(SIGNING_REQUIREMENT.includes(policy.teamID)); assert.ok(SIGNING_REQUIREMENT.includes(policy.developerIDLeafOID));
});

test('unrelated Canvas app is never replaced even beside legacy Blink', t => {
  const f = fixture(t); f.app(join(f.directory, 'Canvas.app'), 'org.example.canvas'); f.app(join(f.directory, 'Blink.app'));
  assert.throws(() => installMountedApp({ ...f, appName: 'Canvas.app' }), /unrelated/);
  assert.equal(f.calls.some(([cmd]) => cmd === 'osascript'), false);
  assert.equal(existsSync(join(f.directory, 'Blink.app')), true);
});

test('signature or graceful-quit failure leaves the existing bundle unchanged', t => {
  for (const failingCommand of ['codesign', 'osascript']) {
    const f = fixture(t); const old = f.app(join(f.directory, 'Blink.app'));
    const run = (cmd, args) => { if (cmd === failingCommand) throw new Error(`failed ${cmd}`); return f.run(cmd, args); };
    assert.throws(() => installMountedApp({ ...f, appName: 'Canvas.app', run }), new RegExp(failingCommand));
    assert.equal(readFileSync(join(old, 'Contents', 'payload'), 'utf8'), 'old');
    assert.equal(existsSync(join(f.directory, 'Canvas.app')), false);
  }
});

test('signed app version mismatch fails before quitting or replacing the installed app', t => {
  const f = fixture(t); const old = f.app(join(f.directory, 'Blink.app'));
  assert.throws(() => installMountedApp({ ...f, appName: 'Canvas.app', expectedVersion: '2.3.0' }), /version 2\.2\.0 does not match selected release 2\.3\.0/);
  assert.equal(f.calls.some(([cmd]) => cmd === 'codesign'), true);
  assert.equal(f.calls.some(([cmd]) => cmd === 'osascript'), false);
  assert.equal(readFileSync(join(old, 'Contents', 'payload'), 'utf8'), 'old');
  assert.equal(existsSync(join(f.directory, 'Canvas.app')), false);
  assert.equal(existsSync(join(f.directory, '.canvas-npm-install.lock')), false);
});

test('a newer app installed during download is retained by the transaction version check', t => {
  const f = fixture(t);
  const current = f.app(join(f.directory, 'Canvas.app'), BUNDLE_ID, 'newer app', '2.4.0');
  f.app(f.mounted, BUNDLE_ID, 'older download', '2.3.0');
  assert.throws(() => installMountedApp({ ...f, appName: 'Canvas.app', expectedVersion: '2.3.0' }), /refusing a downgrade/);
  assert.equal(f.calls.some(([cmd]) => cmd === 'osascript'), false);
  assert.equal(readFileSync(join(current, 'Contents', 'payload'), 'utf8'), 'newer app');
});

test('failed final swap restores both prior app names', t => {
  const f = fixture(t); const old = f.app(join(f.directory, 'Blink.app')); const canonical = f.app(join(f.directory, 'Canvas.app'));
  const rename = (from, to) => { if (from.includes('.canvas-install-') && from.endsWith('/Canvas.app')) throw new Error('simulated swap failure'); renameSync(from, to); };
  assert.throws(() => installMountedApp({ ...f, appName: 'Canvas.app', rename }), /swap failure/);
  for (const path of [old, canonical]) assert.equal(readFileSync(join(path, 'Contents', 'payload'), 'utf8'), 'old');
});

test('both npm aliases forward exact arguments and exit codes, including legacy binary fallback', { skip: process.platform !== 'darwin' || process.arch !== 'arm64' }, t => {
  const f = fixture(t); const binDir = join(f.root, 'bin'); const dist = join(f.root, 'dist'); mkdirSync(binDir); mkdirSync(dist);
  cpSync(join(root, 'bin/blink.mjs'), join(binDir, 'blink.mjs'));
  const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  assert.equal(pkg.bin.canvas, pkg.bin.blink); assert.equal(pkg.bin['canvas-app'], pkg.bin['blink-app']);
  const binary = join(dist, 'blink'); writeFileSync(binary, '#!/bin/sh\nprintf "%s\\n" "$@"\nexit 7\n'); chmodSync(binary, 0o755);
  for (const name of ['blink', 'canvas']) {
    if (name === 'canvas') renameSync(binary, join(dist, 'canvas'));
    const child = spawnSync(process.execPath, [join(binDir, 'blink.mjs'), 'write', 'a note', '--json'], { encoding: 'utf8' });
    assert.equal(child.status, 7); assert.equal(child.stdout, 'write\na note\n--json\n');
  }
});
