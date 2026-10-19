import { lstatSync, mkdirSync, mkdtempSync, renameSync, rmSync } from 'node:fs';
import { join } from 'node:path';

export const BUNDLE_ID = 'dev.arach.blink';
// Matches tools/release/companion-signing.json in arach/lattices.
export const SIGNING_REQUIREMENT = '=anchor apple generic and certificate leaf[subject.OU] = "2U83JFPW66" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists';
const appNames = ['Canvas.app', 'Blink.app'];

function entry(path) {
  try { return lstatSync(path); }
  catch (error) { if (error.code === 'ENOENT') return undefined; throw error; }
}

function hasEntry(path) { return entry(path) !== undefined; }

export function selectRelease(releases) {
  const candidates = [];
  for (const release of releases) {
    if (!release || typeof release !== 'object' || release.draft !== false || release.prerelease !== false) continue;
    const match = /^(canvas|blink)-v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(typeof release.tag_name === 'string' ? release.tag_name : '');
    if (!match || Number(match[2]) < 2 || !match.slice(2).map(Number).every(Number.isSafeInteger)) continue;
    const name = match[1] === 'canvas' ? 'Canvas' : 'Blink';
    const assets = Array.isArray(release.assets) ? release.assets.filter(asset => asset?.name === `${name}.dmg`) : [];
    if (assets.length !== 1 || assets[0].state !== 'uploaded' || !Number.isSafeInteger(assets[0].size) || assets[0].size <= 0 || assets[0].size > 2 * 1024 ** 3 || typeof assets[0].browser_download_url !== 'string') continue;
    let url;
    try {
      url = new URL(assets[0].browser_download_url);
      const expected = ['arach', 'lattices-dev'].map(owner => `/${owner}/lattices/releases/download/${release.tag_name}/${name}.dmg`);
      if (url.origin !== 'https://github.com' || !expected.includes(url.pathname) || url.username || url.password || url.search || url.hash) continue;
    } catch { continue; }
    candidates.push({ version: match.slice(2).map(Number), tag: release.tag_name, appName: `${name}.app`, url: url.href, canonical: name === 'Canvas' });
  }
  candidates.sort((a, b) => b.version[0] - a.version[0] || b.version[1] - a.version[1] || b.version[2] - a.version[2] || Number(b.canonical) - Number(a.canonical));
  if (!candidates.length) throw new Error('No compatible stable Canvas or Blink release is available.');
  return candidates[0];
}

export function mountedAppName(mount) {
  const names = appNames.filter(name => hasEntry(join(mount, name)));
  if (names.length !== 1) throw new Error('Installer image must contain exactly one Canvas.app or Blink.app');
  const info = entry(join(mount, names[0]));
  if (info.isSymbolicLink() || !info.isDirectory()) throw new Error('Installer app must be a real directory, not a symlink');
  return names[0];
}

export function assertNoDowngrade(release, existing, run) {
  for (const path of existing) {
    const version = run('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', join(path, 'Contents', 'Info.plist')], { encoding: 'utf8', stdio: 'pipe' }).trim();
    const parts = /^(\d+)\.(\d+)\.(\d+)$/.exec(version)?.slice(1).map(Number);
    if (!parts) throw new Error(`Cannot safely compare installed version ${version} at ${path}`);
    const comparison = parts[0] - release.version[0] || parts[1] - release.version[1] || parts[2] - release.version[2];
    if (comparison > 0 || comparison === 0 && path.endsWith('/Canvas.app') && !release.canonical) {
      throw new Error(`Installed Canvas ${version} is at least as new as ${release.tag}; refusing a downgrade`);
    }
  }
}

export function readBundleID(path, run) {
  const info = entry(path);
  if (!info) return undefined;
  if (info.isSymbolicLink()) throw new Error(`Refusing an app symlink at ${path}`);
  if (!info.isDirectory()) return undefined;
  try {
    return run('plutil', ['-extract', 'CFBundleIdentifier', 'raw', join(path, 'Contents', 'Info.plist')], { encoding: 'utf8', stdio: 'pipe' }).trim();
  } catch { return undefined; }
}

export function installedApps(directories, run) {
  return directories.flatMap(directory => appNames.map(name => join(directory, name))).filter(path => readBundleID(path, run) === BUNDLE_ID);
}

export function quitRunningApp(run) {
  // Application termination waits for Canvas's asynchronous save flush. A veto
  // or timeout fails the install before any installed bundle is moved.
  run('osascript', ['-e', `with timeout of 60 seconds
  if application id "${BUNDLE_ID}" is running then
    tell application id "${BUNDLE_ID}" to quit
    repeat 120 times
      if application id "${BUNDLE_ID}" is not running then return
      delay 0.25
    end repeat
    error "Canvas is still saving or declined to quit; no app was replaced."
  end if
end timeout`], { stdio: 'pipe', timeout: 65000 });
}

// Filesystem transaction is injectable at the rename boundary so rollback can
// be exercised without touching installed apps or requiring a mounted image.
export function installMountedApp({ mounted, appName, expectedVersion, canonicalRelease = appName === 'Canvas.app', directory, run, rename = renameSync }) {
  if (!appNames.includes(appName)) throw new Error('Unexpected app name');
  if (typeof expectedVersion !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(expectedVersion)) throw new Error('Expected a stable release version');
  if (readBundleID(mounted, run) !== BUNDLE_ID) throw new Error('Unexpected mounted app identity');
  mkdirSync(directory, { recursive: true });
  const lock = join(directory, '.canvas-npm-install.lock');
  try { mkdirSync(lock, { mode: 0o700 }); }
  catch { throw new Error(`Another Canvas npm install may be running (${lock}).`); }
  let transaction;
  let preserve = false;
  try {
    const destination = join(directory, appName);
    const paths = appNames.map(name => join(directory, name));
    // Protect an unrelated Canvas.app even when a genuine legacy Blink exists.
    if (hasEntry(destination) && readBundleID(destination, run) !== BUNDLE_ID) throw new Error(`Refusing to replace an unrelated app at ${destination}`);
    const previous = paths.filter(path => hasEntry(path) && readBundleID(path, run) === BUNDLE_ID);
    transaction = mkdtempSync(join(directory, '.canvas-install-'));
    const staged = join(transaction, appName);
    run('ditto', [mounted, staged], { stdio: 'pipe' });
    run('codesign', ['--verify', '--deep', '--strict', '-R', SIGNING_REQUIREMENT, staged], { stdio: 'pipe' });
    if (readBundleID(staged, run) !== BUNDLE_ID) throw new Error('Unexpected app bundle identifier in downloaded app');
    const stagedVersion = run('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', join(staged, 'Contents', 'Info.plist')], { encoding: 'utf8', stdio: 'pipe' }).trim();
    if (stagedVersion !== expectedVersion) throw new Error(`Downloaded app version ${stagedVersion} does not match selected release ${expectedVersion}`);
    // Another updater may have finished while this download was in progress.
    // Recheck the actual installed bundles while holding the installation lock.
    const selectedRelease = { version: expectedVersion.split('.').map(Number), canonical: canonicalRelease, tag: `${canonicalRelease ? 'canvas' : 'blink'}-v${expectedVersion}` };
    assertNoDowngrade(selectedRelease, previous, run);
    quitRunningApp(run);
    const backups = [];
    try {
      for (const path of previous) {
        if (readBundleID(path, run) !== BUNDLE_ID) throw new Error(`App identity changed during installation: ${path}`);
        const backup = join(transaction, `previous-${backups.length}.app`);
        rename(path, backup);
        backups.push([path, backup]);
      }
      if (hasEntry(destination)) throw new Error(`Installation destination appeared during update: ${destination}`);
      rename(staged, destination);
    } catch (error) {
      const failures = [];
      for (const [path, backup] of backups.reverse()) {
        try {
          if (hasEntry(path)) throw new Error(`restore destination already exists: ${path}`);
          rename(backup, path);
        } catch (restoreError) { failures.push(`${backup}: ${restoreError.message}`); }
      }
      if (failures.length) {
        preserve = true;
        throw new Error(`Install failed; previous app retained for recovery at ${failures.join('; ')}`, { cause: error });
      }
      throw error;
    }
    return destination;
  } finally {
    if (transaction && !preserve) rmSync(transaction, { recursive: true, force: true });
    rmSync(lock, { recursive: true, force: true });
  }
}
