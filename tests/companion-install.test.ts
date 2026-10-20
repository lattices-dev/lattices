import { expect, test } from 'bun:test';
import { installCompanion } from '../bin/companion-install';
import type { CompanionInstallOperations } from '../bin/companion-install';
import type { CompanionRelease } from '../bin/companion-release';
import { findCompanionBundle } from '../bin/companion-installer';
import { mkdtemp, mkdir, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const release: CompanionRelease = { product: 'blink', version: '2.0.0', tag: 'blink-v2.0.0', assetURL: '', size: 1, bundleID: 'dev.arach.blink' };
function fixture(overrides: Partial<CompanionInstallOperations> = {}) {
  const calls: string[] = [];
  const op: CompanionInstallOperations = {
    findInstalled: async () => { calls.push('find'); return undefined; },
    createStaging: async () => { calls.push('staging'); return '/owned/staging'; },
    download: async () => { calls.push('download'); return '/owned/image'; },
    mountReadOnly: async () => { calls.push('mount'); return '/owned/mount'; },
    stageExpectedApp: async () => { calls.push('copy'); return '/owned/staging/Blink.app'; },
    verify: async () => { calls.push('verify'); },
    commitExclusive: async () => { calls.push('commit'); return '/Applications/Blink.app'; },
    detach: async () => { calls.push('detach'); },
    removeStaging: async () => { calls.push('cleanup'); },
    ...overrides,
  };
  return { calls, op };
}
test('verifies before exclusive commit and cleans operation resources', async () => {
  const { calls, op } = fixture();
  expect((await installCompanion(release, op)).status).toBe('installed');
  expect(calls).toEqual(['find', 'staging', 'download', 'mount', 'copy', 'verify', 'find', 'commit', 'detach', 'cleanup']);
});
test('rejects invalid artifacts without commit and cleans up', async () => {
  const { calls, op } = fixture({ verify: async () => { throw new Error('Wrong signing team'); } });
  expect((await installCompanion(release, op)).status).toBe('failed');
  expect(calls).not.toContain('commit'); expect(calls.slice(-2)).toEqual(['detach', 'cleanup']);
});
test('does not download for independently installed app', async () => {
  const { calls, op } = fixture({ findInstalled: async () => '/Users/me/Applications/Blink.app' });
  expect((await installCompanion(release, op)).status).toBe('already-installed'); expect(calls).toEqual([]);
});
test('cancellation before commit never installs and still cleans', async () => {
  const abort = new AbortController();
  const { calls, op } = fixture({ verify: async () => { abort.abort(); } });
  expect((await installCompanion(release, op, { signal: abort.signal })).status).toBe('cancelled');
  expect(calls).not.toContain('commit'); expect(calls.slice(-2)).toEqual(['detach', 'cleanup']);
});
test('commit success survives late cancellation, cleanup and UI failures', async () => {
  const abort = new AbortController();
  const { op } = fixture({
    commitExclusive: async () => { abort.abort(); return '/Applications/Blink.app'; },
    detach: async () => { throw new Error('busy'); },
  });
  const result = await installCompanion(release, op, { signal: abort.signal, onPhase: phase => { if (phase === 'installed') throw new Error('UI gone'); } });
  expect(result.status).toBe('installed');
  if (result.status === 'installed') expect(result.cleanupErrors.length).toBe(1);
});
test('concurrent installation and exclusive-commit conflict preserve existing app', async () => {
  let lookups = 0;
  const { calls, op } = fixture({ findInstalled: async () => ++lookups === 2 ? '/Applications/Blink.app' : undefined });
  expect((await installCompanion(release, op)).status).toBe('already-installed'); expect(calls).not.toContain('commit');
  const conflict = fixture({ commitExclusive: async () => { throw new Error('Target exists'); } });
  expect((await installCompanion(release, conflict.op)).status).toBe('failed');
});

test('rename images accept one known bundle basename and reject ambiguous or linked bundles', async () => {
  const mount = await mkdtemp(join(tmpdir(), 'companion-image-'));
  const canvas = join(mount, 'Canvas.app'), blink = join(mount, 'Blink.app');
  try {
    await expect(findCompanionBundle(mount, 'canvas')).rejects.toThrow('exactly one');
    await mkdir(canvas);
    expect(await findCompanionBundle(mount, 'blink')).toBe(canvas);
    expect(await findCompanionBundle(mount, 'canvas')).toBe(canvas);
    await expect(findCompanionBundle(mount, 'action')).rejects.toThrow('exactly one');
    await mkdir(blink);
    await expect(findCompanionBundle(mount, 'canvas')).rejects.toThrow('exactly one');
    await rm(canvas, { recursive: true });
    expect(await findCompanionBundle(mount, 'canvas')).toBe(blink);
    await rm(blink, { recursive: true });
    await mkdir(join(mount, 'elsewhere'));
    await symlink(join(mount, 'elsewhere'), blink);
    await expect(findCompanionBundle(mount, 'blink')).rejects.toThrow('regular bundle');
  } finally { await rm(mount, { recursive: true, force: true }); }
});
