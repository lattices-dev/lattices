/** Real DMG acceptance probe. Writes only to an operation-owned temporary root;
 * never discovers, opens, replaces, or quits an installed application.
 * Usage: bun tests/companion-artifact-install.ts <canvas|blink|action|speech> <version> <dmg>
 */
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { installCompanion } from '../bin/companion-install';
import { verifyCompanionBundle } from '../bin/companion-installer';
import { commitCompanionExclusive } from '../bin/companion-commit';
import { companionDistribution, type CompanionReleaseProduct } from '../bin/companion-release';

const [product, version, input] = process.argv.slice(2);
if (!['canvas', 'blink', 'action', 'speech'].includes(product!) || !version || !input) {
  throw new Error('Expected product, version and local DMG path.');
}
const policy = companionDistribution.products[product as CompanionReleaseProduct];
const artifact = resolve(input);
const root = await mkdtemp(join(tmpdir(), 'lattices-artifact-install-'));
const appName = policy.asset.replace(/\.dmg$/, '.app');
const destination = join(root, appName);
const run = (program: string, args: string[]) => execFileSync(program, args, { encoding: 'utf8' });
const release = { product: product as CompanionReleaseProduct, version,
  tag: `${policy.tagPrefix}${version}`, bundleID: policy.bundleID,
  assetURL: '', size: (await stat(artifact)).size };
let attached: string | undefined;
try {
  const result = await installCompanion(release, {
    findInstalled: async () => undefined,
    createStaging: () => mkdtemp(join(root, 'stage-')),
    download: async () => artifact,
    mountReadOnly: async path => {
      const mount = join(root, 'mount'); await mkdir(mount);
      run('/usr/bin/hdiutil', ['attach', '-readonly', '-nobrowse', '-mountpoint', mount, path]);
      attached = mount; return mount;
    },
    stageExpectedApp: async (mount, staging) => {
      const source = join(mount, appName);
      await verifyCompanionBundle(source, release);
      const staged = join(staging, appName);
      run('/usr/bin/ditto', ['--rsrc', '--extattr', source, staged]);
      run('/usr/bin/xattr', ['-w', 'com.apple.quarantine', '0083;0;LatticesArtifactProbe;', staged]);
      return staged;
    },
    verify: verifyCompanionBundle,
    commitExclusive: async app => { await commitCompanionExclusive(app, destination); return destination; },
    detach: async mount => { run('/usr/bin/hdiutil', ['detach', mount]); attached = undefined; },
    removeStaging: path => rm(path, { recursive: true }),
  });
  if (result.status !== 'installed' || result.cleanupErrors.length) throw new Error(JSON.stringify(result));
  await verifyCompanionBundle(destination, release);
  console.log(JSON.stringify({ product, version, result: 'passed', mountedAndStagedTrust: true,
    quarantine: true, exclusiveCommit: true, installedApplicationsTouched: false }));
} finally {
  if (attached) run('/usr/bin/hdiutil', ['detach', attached]);
  await rm(root, { recursive: true });
}
