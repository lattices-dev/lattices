/** Canonical distribution identity; legacy package names remain supported. */
export const distribution = {
  repository: 'lattices-dev/lattices',
  legacyRepository: 'arach/lattices',
  // The numeric repository identity survives owner/name transfers without redirects.
  releasesAPI: 'https://api.github.com/repositories/1171006654/releases',
  package: '@lattices/lattices',
  legacyPackages: ['@arach/lattices', '@lattices/cli'],
} as const;

/** Keep upgrades in the installed package directory, including LaunchAgent paths. */
export function installedPackageName(name: unknown): string {
  return typeof name === 'string' && [distribution.package, ...distribution.legacyPackages].some(value => value === name)
    ? name : distribution.package;
}
