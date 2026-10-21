#!/usr/bin/env node
// Canvas and the legacy blink-app command use one identity-preserving installer.
import { execFileSync } from 'node:child_process';
import { createWriteStream, mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { get } from 'node:https';
import { pipeline } from 'node:stream/promises';
import { assertNoDowngrade, installedApps, installMountedApp, mountedAppName, selectRelease } from './canvas-app-support.mjs';

const REPO = 'lattices-dev/lattices';
const directories = ['/Applications', join(homedir(), 'Applications')];

function httpsGet(url, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (new URL(url).protocol !== 'https:' || redirects > 10) return reject(new Error('Unsafe or excessive download redirect'));
    get(url, { headers: { 'User-Agent': 'canvas-app' } }, res => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return httpsGet(new URL(res.headers.location, url).href, redirects + 1).then(resolve, reject);
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error(`HTTP ${res.statusCode} for ${url}`)); }
      resolve(res);
    }).on('error', reject);
  });
}

async function latestRelease() {
  const releases = [];
  for (let page = 1; page <= 20; page++) {
    const response = await httpsGet(`https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}`);
    const chunks = [];
    for await (const chunk of response) chunks.push(chunk);
    const batch = JSON.parse(Buffer.concat(chunks).toString());
    if (!Array.isArray(batch)) throw new Error('Invalid GitHub release response');
    releases.push(...batch);
    if (batch.length < 100) return selectRelease(releases);
  }
  throw new Error('GitHub release listing exceeded the supported pagination limit');
}

async function ensureInstalled(force) {
  const existing = installedApps(directories, execFileSync);
  if (existing.length && !force) return existing[0];
  const release = await latestRelease();
  assertNoDowngrade(release, existing, execFileSync);
  console.log(`Installing ${release.tag}…`);
  const download = mkdtempSync(join(tmpdir(), 'canvas-download-'));
  const mount = mkdtempSync(join(tmpdir(), 'canvas-mount-'));
  let attached = false;
  let detached = false;
  try {
    const dmg = join(download, 'release.dmg');
    await pipeline(await httpsGet(release.url), createWriteStream(dmg));
    execFileSync('spctl', ['--assess', '--type', 'open', '--context', 'context:primary-signature', dmg], { stdio: 'pipe' });
    execFileSync('hdiutil', ['attach', '-nobrowse', '-readonly', '-mountpoint', mount, dmg], { stdio: 'pipe' });
    attached = true;
    const appName = mountedAppName(mount);
    const mounted = join(mount, appName);
    const path = installMountedApp({ mounted, appName, expectedVersion: release.version.join('.'), canonicalRelease: release.canonical, directory: existing.length ? dirname(existing[0]) : '/Applications', run: execFileSync });
    console.log(`Installed ${path}`);
    return path;
  } finally {
    if (attached) {
      try { execFileSync('hdiutil', ['detach', mount, '-quiet'], { stdio: 'pipe' }); detached = true; }
      catch { console.error(`Could not detach the installer image at ${mount}; eject it manually.`); }
    }
    if (!attached || detached) rmSync(mount, { recursive: true, force: true });
    rmSync(download, { recursive: true, force: true });
  }
}

function launch(path) {
  execFileSync('open', [path], { stdio: 'inherit' });
  console.log(`Canvas launched (${path}).`);
}

if (process.platform !== 'darwin') { console.error('Canvas (@arach/blink) runs on macOS only.'); process.exit(1); }
try {
  const command = process.argv[2];
  if (command === 'install' || command === 'update') await ensureInstalled(true);
  else if (command === 'open') {
    const path = installedApps(directories, execFileSync)[0];
    if (!path) throw new Error('Canvas is not installed (run `canvas app install` first)');
    launch(path);
  } else if (command === 'path') console.log(installedApps(directories, execFileSync)[0] ?? '/Applications/Canvas.app');
  else if (command === undefined) launch(await ensureInstalled(false));
  else throw new Error(`Unknown command '${command}' (expected install, update, open, or path)`);
} catch (error) {
  console.error(`canvas-app: ${error.message}`);
  console.error(`Download manually: https://github.com/${REPO}/releases`);
  process.exit(1);
}
