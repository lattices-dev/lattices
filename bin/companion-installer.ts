import signingPolicy from '../tools/release/companion-signing.json';
import { acquireCompanionLock } from './companion-lock';
import { commitCompanionExclusive } from './companion-commit';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, mkdtemp, lstat, rm, open, statfs } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { companionAppNames, companionDistribution, companionInstallIdentity, fetchCompanionRelease } from './companion-release';
import type { CompanionRelease, CompanionReleaseProduct } from './companion-release';
import { installCompanion } from './companion-install';
import type { CompanionInstallOperations } from './companion-install';

const execute = promisify(execFile);
// Shared distributable policy, corroborated by Action release configuration.
// Release operators must retain this identity or update the reviewed trust policy.
export const companionSigningTeam = signingPolicy.teamID;
const allowedDownloadHosts = new Set(['github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com']);

async function command(program: string, args: string[], signal?: AbortSignal): Promise<string> {
  try { return (await execute(program, args, { signal, maxBuffer: 1024 * 1024 })).stdout.trim(); }
  catch (error) { throw new Error(`${program.split('/').pop()} failed: ${error instanceof Error ? error.message : String(error)}`); }
}
async function exists(path: string): Promise<boolean> {
  try { await lstat(path); return true; } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
    throw error;
  }
}
async function plist(app: string, key: string): Promise<string> {
  return command('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, join(app, 'Contents/Info.plist')]);
}

/** Release tags and asset names may straddle a rename; accept one known basename,
 * then require the unchanged signed identity in verifyCompanionBundle. */
export async function findCompanionBundle(mount: string, product: CompanionReleaseProduct): Promise<string> {
  const candidates: string[] = [];
  for (const name of companionAppNames(product)) {
    const path = join(mount, name);
    if (await exists(path)) candidates.push(path);
  }
  if (candidates.length !== 1) throw new Error('The release must contain exactly one supported app bundle.');
  const candidate = candidates[0]!;
  const info = await lstat(candidate);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('The downloaded app is not a regular bundle directory.');
  return candidate;
}

export async function verifyCompanionBundle(app: string, release: CompanionRelease, signal?: AbortSignal): Promise<void> {
  if (process.platform !== 'darwin') throw new Error('Companion installation requires macOS.');
  const info = await lstat(app);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('The downloaded app is not a regular bundle directory.');
  if (await plist(app, 'CFBundleIdentifier') !== release.bundleID) throw new Error('The downloaded app has the wrong bundle identity.');
  if (await plist(app, 'CFBundlePackageType') !== 'APPL') throw new Error('The downloaded bundle is not an application.');
  const executable = await plist(app, 'CFBundleExecutable');
  if (!executable || executable.includes('/') || executable === '.' || executable === '..') throw new Error('Invalid app executable.');
  await command('/usr/bin/codesign', ['--verify', '--deep', '--strict', '-R', `=anchor apple generic and certificate leaf[subject.OU] = "${companionSigningTeam}" and certificate leaf[field.${signingPolicy.developerIDLeafOID}] exists`, app], signal);
  await command('/usr/sbin/spctl', ['--assess', '--type', 'execute', '--verbose=2', app], signal);
  const architectures = await command('/usr/bin/lipo', ['-archs', join(app, 'Contents/MacOS', executable)], signal);
  const expected = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  if (!architectures.split(/\s+/).includes(expected)) throw new Error(`This app does not support ${expected}.`);
  let minimum: string;
  try { minimum = await plist(app, 'LSMinimumSystemVersion'); }
  catch { throw new Error('The app does not declare its minimum macOS version.'); }
  const current = await command('/usr/bin/sw_vers', ['-productVersion'], signal);
  const compare = (a: string, b: string) => {
    const aa = a.split('.').map(Number), bb = b.split('.').map(Number);
    if (!aa.every(Number.isFinite) || !bb.every(Number.isFinite)) throw new Error('Invalid macOS version requirement.');
    for (let i = 0; i < Math.max(aa.length, bb.length); i++) {
      if ((aa[i] ?? 0) !== (bb[i] ?? 0)) return (aa[i] ?? 0) - (bb[i] ?? 0);
    }
    return 0;
  };
  if (compare(current, minimum) < 0) throw new Error(`This app requires macOS ${minimum} or newer.`);
}

async function download(release: CompanionRelease, destination: string, signal?: AbortSignal): Promise<void> {
  let url = new URL(release.assetURL);
  let response: Response | undefined;
  for (let hop = 0; hop < 6; hop++) {
    if (url.protocol !== 'https:' || !allowedDownloadHosts.has(url.hostname) || url.username || url.password || url.port) {
      throw new Error('The release download redirected outside the trusted artifact hosts.');
    }
    response = await fetch(url, { signal, redirect: 'manual' });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get('location'); await response.body?.cancel();
      if (!location) throw new Error('Invalid release redirect.');
      url = new URL(location, url); response = undefined; continue;
    }
    break;
  }
  if (!response?.ok || !response.body) throw new Error(`Release download failed (HTTP ${response?.status ?? 'redirect limit'}).`);
  const file = await open(destination, 'wx', 0o600);
  const reader = response.body.getReader();
  let size = 0;
  try {
    while (true) {
      signal?.throwIfAborted();
      const { value, done } = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > release.size) throw new Error('The downloaded artifact exceeds its advertised size.');
      let offset = 0;
      while (offset < value.byteLength) offset += (await file.write(value, offset)).bytesWritten;
    }
    if (size !== release.size) throw new Error('The release download was incomplete.');
    await file.sync();
  } finally { await reader.cancel().catch(() => {}); await file.close(); }
  await quarantine(destination);
}
async function quarantine(path: string): Promise<void> {
  await command('/usr/bin/xattr', ['-w', 'com.apple.quarantine', `0083;${Math.floor(Date.now()/1000).toString(16)};Lattices;${randomUUID()}`, path]);
}

export async function runCompanionInstaller(product: CompanionReleaseProduct, signal?: AbortSignal) {
  if (process.platform !== 'darwin') throw new Error('Companion installation requires macOS.');
  const applications = join(homedir(), 'Applications');
  await mkdir(applications, { recursive: true });
  const appNames = companionAppNames(product);
  const findInstalled = async (bundleID: string) => {
    signal?.throwIfAborted();
    const indexed = await command('/usr/bin/mdfind', [`kMDItemCFBundleIdentifier == '${bundleID}'`], signal);
    const candidates = [...appNames.flatMap(name => [join(applications, name), join('/Applications', name)]), ...indexed.split('\n').filter(Boolean)];
    for (const candidate of candidates) {
      try {
        const info = await lstat(candidate);
        if (!candidate.endsWith('.app') || !info.isDirectory() || info.isSymbolicLink()) continue;
        if (await plist(candidate, 'CFBundleIdentifier') !== bundleID || await plist(candidate, 'CFBundlePackageType') !== 'APPL') continue;
        const executable = await plist(candidate, 'CFBundleExecutable');
        if (!executable || executable.includes('/') || executable === '.' || executable === '..') continue;
        if ((await lstat(join(candidate, 'Contents/MacOS', executable))).isFile()) return candidate;
      } catch { /* Removed or invalid candidate; keep discovering. */ }
    }
  };
  const unlock = await acquireCompanionLock(join(applications, `.lattices-install-${companionInstallIdentity(product)}.lock`));
  try {
    const existing = await findInstalled(companionDistribution.products[product].bundleID);
    if (existing) return { status: 'already-installed' as const, path: existing, cleanupErrors: [] as string[] };
    const release = await fetchCompanionRelease(product, { signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(30_000)]) });
    if (!release) throw new Error(`No supported ${product} release is published yet.`);
    const disk = await statfs(applications);
    if (disk.bavail * disk.bsize < release.size * 4) throw new Error('Not enough disk space to download, verify and stage this app. Free space and retry.');
    let mountedPath: string | undefined;
    const operations: CompanionInstallOperations = {
      findInstalled,
      createStaging: () => mkdtemp(join(applications, '.lattices-staging-')),
      download: async (release, staging, signal) => { const path = join(staging, 'download.dmg'); await download(release, path, signal); return path; },
      mountReadOnly: async (artifact, signal) => {
        const mount = join(artifact, '..', 'mount'); await mkdir(mount);
        mountedPath = mount;
        await command('/usr/bin/hdiutil', ['attach', '-readonly', '-nobrowse', '-mountpoint', mount, artifact]);
        return mount;
      },
      stageExpectedApp: async (mount, staging, release, signal) => {
        const source = await findCompanionBundle(mount, release.product);
        await verifyCompanionBundle(source, release, signal);
        const staged = join(staging, basename(source));
        await command('/usr/bin/ditto', ['--rsrc', '--extattr', source, staged], signal);
        await quarantine(staged); return staged;
      },
      verify: verifyCompanionBundle,
      commitExclusive: async app => {
        const appName = basename(app);
        if (!appNames.includes(appName)) throw new Error('Unsupported staged app bundle.');
        const destination = join(applications, appName);
        if (await exists(destination)) throw new Error(`An app already exists at ${destination}; it was not replaced.`);
        await commitCompanionExclusive(app, destination);
        return destination;
      },
      detach: async mount => { await command('/usr/bin/hdiutil', ['detach', mount]); mountedPath = undefined; },
      removeStaging: async staging => {
        if (mountedPath) {
          try { await command('/usr/bin/hdiutil', ['detach', mountedPath]); mountedPath = undefined; }
          catch { throw new Error(`Staging retained at ${staging}; detach ${mountedPath} before removing it.`); }
        }
        await rm(staging, { recursive: true, force: true });
      },
    };
    return await installCompanion(release, operations, { signal, onPhase: phase => process.stdout.write(`${JSON.stringify({ phase })}\n`) });
  } finally { await unlock(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const product = process.argv[2];
  if (product === '--check-runtime') {
    const temporary = await mkdtemp(join(tmpdir(), 'companion-runtime-'));
    try {
      const unlock = await acquireCompanionLock(join(temporary, 'lock'));
      try {
        const source = join(temporary, 'source.app');
        await mkdir(source);
        await commitCompanionExclusive(source, join(temporary, 'destination.app'));
        console.log('Companion installer runtime verified: kernel lock and exclusive commit.');
      } finally { await unlock(); }
    } finally { await rm(temporary, { recursive: true, force: true }); }
  } else if (product !== 'canvas' && product !== 'blink' && product !== 'action' && product !== 'speech') { console.error('Usage: companion-installer.ts canvas|blink|action|speech'); process.exitCode = 1; }
  else {
    const abort = new AbortController();
    process.once('SIGINT', () => abort.abort()); process.once('SIGTERM', () => abort.abort());
    try {
      const result = await runCompanionInstaller(product, abort.signal);
      process.stdout.write(`${JSON.stringify(result)}\n`);
      if (result.status === 'failed' || result.status === 'cancelled') process.exitCode = 1;
    } catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; }
  }
}
