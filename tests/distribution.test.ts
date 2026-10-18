import { expect, test } from 'bun:test';
import { installedPackageName } from '../bin/distribution';

test('upgrades preserve the package directory for every supported installed name', () => {
  for (const name of ['@lattices/lattices', '@arach/lattices', '@lattices/cli']) {
    expect(installedPackageName(name)).toBe(name);
  }
});

test('unknown or missing package metadata defaults to the canonical package', () => {
  for (const name of [undefined, null, 42, '', '@other/lattices']) {
    expect(installedPackageName(name)).toBe('@lattices/lattices');
  }
});
