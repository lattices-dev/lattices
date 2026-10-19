import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const product = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const tools = join(product, 'tools/release');
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'canvas-release-contract-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, 'bin'); const output = join(root, 'output'); mkdirSync(bin); mkdirSync(output);
  function command(name, source) { const path = join(bin, name); writeFileSync(path, `#!${process.execPath}\n${source}`); chmodSync(path, 0o755); }
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, BLINK_SKIP_SIGN: '1', BLINK_SKIP_NOTARIZE: '1' };
  return { root, bin, output, command, env };
}

test('separate images contain the real app names required by current and published legacy installers', t => {
  const f = fixture(t); const bundle = join(f.root, 'Canvas.app'); mkdirSync(join(bundle, 'Contents/MacOS'), { recursive: true });
  const info = { CFBundleName: 'Canvas', CFBundleDisplayName: 'Canvas', CFBundleExecutable: 'Canvas', CFBundleIdentifier: 'dev.arach.blink', CFBundleShortVersionString: '2.3.0' };
  writeFileSync(join(bundle, 'Contents/Info.plist'), JSON.stringify(info)); writeFileSync(join(bundle, 'Contents/MacOS/Canvas'), 'signed-app-fixture');
  f.command('plutil', `const fs=require('node:fs'); const args=process.argv.slice(2); console.log(JSON.parse(fs.readFileSync(args.at(-1),'utf8'))[args[1]]);`);
  f.command('ditto', `require('node:fs').cpSync(process.argv[2],process.argv[3],{recursive:true});`);
  f.command('hdiutil', `const fs=require('node:fs'), path=require('node:path'); const args=process.argv.slice(2); const stage=args[args.indexOf('-srcfolder')+1]; const apps=fs.readdirSync(stage).filter(n=>n.endsWith('.app')); const app=path.join(stage,apps[0]); fs.writeFileSync(args.at(-1),JSON.stringify({apps,symlink:fs.lstatSync(app).isSymbolicLink(),info:JSON.parse(fs.readFileSync(path.join(app,'Contents/Info.plist'),'utf8')),executable:fs.readFileSync(path.join(app,'Contents/MacOS/Canvas'),'utf8')}));`);
  const result = spawnSync('bash', [join(tools, 'package-dmgs.sh'), bundle, f.output], { env: f.env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  for (const name of ['Canvas', 'Blink']) {
    const image = JSON.parse(readFileSync(join(f.output, `${name}.dmg`), 'utf8'));
    assert.deepEqual(image.apps, [`${name}.app`]); assert.equal(image.symlink, false);
    assert.deepEqual(image.info, info); assert.equal(image.executable, 'signed-app-fixture');
  }
});

function fakeGitHub(f, conflict = false) {
  const log = join(f.root, 'github.jsonl'); const sha = 'a'.repeat(40);
  f.command('gh', `const fs=require('node:fs'); const args=process.argv.slice(2); fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(args)+'\\n'); if(args[0]==='api'){ const path=args[1]==='--paginate'?args[2]:args[1]; if(path.includes('matching-refs') && ${JSON.stringify(conflict)} && path.endsWith('blink-v2.3.0')) console.log('refs/tags/blink-v2.3.0'); else if(path.includes('/commits/')) console.log(${JSON.stringify(conflict)} && path.endsWith('blink-v2.3.0') ? 'b'.repeat(40) : ${JSON.stringify(sha)}); }`);
  for (const name of ['Canvas.dmg', 'Blink.dmg', 'canvas-macos-arm64', 'blink-macos-arm64']) {
    const path = join(f.output, name); writeFileSync(path, name.endsWith('.dmg') ? name : '#!/bin/sh\necho 2.3.0\n'); chmodSync(path, 0o755);
  }
  return { log, sha };
}

test('publisher creates both release channels at the same commit with correct legacy assets', t => {
  const f = fixture(t); const { log, sha } = fakeGitHub(f);
  const result = spawnSync('bash', [join(tools, 'publish-assets.sh'), '2.3.0', 'example/repo', sha, f.output], { env: f.env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  const commands = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
  const creates = commands.filter(args => args[0] === 'release' && args[1] === 'create');
  assert.deepEqual(creates.map(args => args[2]), ['canvas-v2.3.0', 'blink-v2.3.0']);
  for (const args of creates) { assert.equal(args[args.indexOf('--target')+1], sha); assert.ok(args.includes('--latest=false')); }
  assert.ok(creates[0].includes(join(f.output, 'Canvas.dmg')));
  assert.ok(creates[1].includes(join(f.output, 'Blink.dmg')));
  assert.equal(commands.some(args => args.includes('blink-v2.2.0')), false);
});

test('conflicting legacy tag aborts before either release is published', t => {
  const f = fixture(t); const { log, sha } = fakeGitHub(f, true);
  const result = spawnSync('bash', [join(tools, 'publish-assets.sh'), '2.3.0', 'example/repo', sha, f.output], { env: f.env, encoding: 'utf8' });
  assert.notEqual(result.status, 0); assert.match(result.stderr, /Refusing to change blink-v2.3.0/);
  assert.equal(readFileSync(log, 'utf8').includes('"release"'), false);
});

test('combined ship command refuses unchecked existing images before building or publishing', t => {
  const f = fixture(t); const { log } = fakeGitHub(f);
  const result = spawnSync('bash', [join(tools, 'ship.sh'), '--skip-dmg'], { env: f.env, encoding: 'utf8' });
  assert.notEqual(result.status, 0); assert.match(result.stderr, /--skip-dmg is only supported with --dry-run/);
  assert.throws(() => readFileSync(log), { code: 'ENOENT' });
});

test('npm publication requires the canonical release binary and version sources agree', () => {
  const pkg = JSON.parse(readFileSync(join(product, 'packages/npm/package.json'), 'utf8'));
  const cli = readFileSync(join(product, 'Sources/BlinkCLI/BlinkCLI.swift'), 'utf8');
  assert.match(cli, new RegExp(`version: "${pkg.version.replaceAll('.', '\\.')}"`));
  const workflow = readFileSync(resolve(product, '../../.github/workflows/release-blink-npm.yml'), 'utf8');
  assert.match(workflow, /release_tag=canvas-v\$version/); assert.match(workflow, /asset="canvas-macos-arm64"/);
  assert.doesNotMatch(workflow, /RELEASE_TAG="blink-v/);
});

test('npm workflow rejects a canonical release from another source commit before downloading its binary', t => {
  const f = fixture(t); const { log } = fakeGitHub(f);
  f.command('git', `console.log('b'.repeat(40));`);
  const workflow = readFileSync(resolve(product, '../../.github/workflows/release-blink-npm.yml'), 'utf8');
  const step = workflow.split('      - name: Download and verify signed CLI\n')[1].split('      - name: Test command and installer compatibility\n')[0];
  const script = step.split('        run: |\n')[1].replace(/^          /gm, '');
  const result = spawnSync('bash', ['-c', script], {
    cwd: f.root,
    env: { ...f.env, GITHUB_REPOSITORY: 'example/repo', RELEASE_TAG: 'canvas-v2.3.0', VERSION: '2.3.0' },
    encoding: 'utf8',
  });
  assert.notEqual(result.status, 0); assert.match(result.stderr, /but this package source is/);
  const commands = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(commands.some(args => args[0] === 'release' && args[1] === 'download'), false);
});
