import { distribution } from './distribution';

/** Product-scoped release policy shared by companion installer entry points. */
export type CompanionReleaseProduct = 'canvas' | 'blink' | 'action' | 'speech';

export const companionDistribution = {
  releasesAPI: distribution.releasesAPI,
  downloadOrigin: 'https://github.com',
  downloadPrefix: `/${distribution.repository}/releases/download/`,
  legacyDownloadPrefix: `/${distribution.legacyRepository}/releases/download/`,
  products: {
    canvas: { tagPrefix: 'canvas-v', asset: 'Canvas.dmg', bundleID: 'dev.arach.blink' },
    blink: { tagPrefix: 'blink-v', asset: 'Blink.dmg', bundleID: 'dev.arach.blink' },
    action: { tagPrefix: 'action-v', asset: 'Action.dmg', bundleID: 'dev.lattices.Action' },
    speech: { tagPrefix: 'speech-v', asset: 'Speech.dmg', bundleID: 'dev.lattices.Speech' },
  },
} as const;

/** Canvas retains Blink's install lock and bundle identity during the rename. */
export function companionInstallIdentity(product: CompanionReleaseProduct): Exclude<CompanionReleaseProduct, 'canvas'> {
  return product === 'canvas' ? 'blink' : product;
}

function releasePolicies(product: CompanionReleaseProduct) {
  return companionInstallIdentity(product) === 'blink'
    ? [companionDistribution.products.canvas, companionDistribution.products.blink]
    : [companionDistribution.products[product]];
}

export function companionAppNames(product: CompanionReleaseProduct): string[] {
  return releasePolicies(product).map(policy => policy.asset.replace(/\.dmg$/, '.app'));
}

export function companionReleaseAppName(release: CompanionRelease): string {
  const policy = releasePolicies(release.product).find(policy => release.tag === `${policy.tagPrefix}${release.version}`);
  if (!policy) throw new Error('The release has no supported app bundle contract.');
  return policy.asset.replace(/\.dmg$/, '.app');
}

export interface CompanionRelease {
  product: CompanionReleaseProduct;
  version: string;
  tag: string;
  assetURL: string;
  size: number;
  bundleID: string;
}

const maximumAssetBytes = 2 * 1024 * 1024 * 1024;

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}

function versionParts(version: string): number[] | undefined {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)) return;
  const parts = version.split('.').map(Number);
  return parts.every(Number.isSafeInteger) ? parts : undefined;
}

/** Invalid or unrelated releases cannot become an install candidate. */
export function selectCompanionRelease(
  product: CompanionReleaseProduct,
  releases: readonly unknown[],
): CompanionRelease | undefined {
  const policies = releasePolicies(product);
  let selected: CompanionRelease | undefined;
  let selectedVersion = [-1, -1, -1];
  let selectedPriority = Infinity;
  for (const raw of releases) {
    const release = record(raw);
    if (!release || release.draft !== false || release.prerelease !== false) continue;
    const tag = release.tag_name;
    if (typeof tag !== 'string') continue;
    const priority = policies.findIndex(policy => tag.startsWith(policy.tagPrefix));
    const policy = policies[priority];
    if (!policy) continue;
    const version = tag.slice(policy.tagPrefix.length);
    const parts = versionParts(version);
    if (!parts || !Array.isArray(release.assets)) continue;
    const matches = release.assets.map(record).filter(asset => asset?.name === policy.asset);
    if (matches.length !== 1) continue;
    const asset = matches[0]!;
    if (asset.state !== 'uploaded' || typeof asset.size !== 'number'
        || !Number.isSafeInteger(asset.size) || asset.size <= 0 || asset.size > maximumAssetBytes
        || typeof asset.browser_download_url !== 'string') continue;
    let url: URL;
    try { url = new URL(asset.browser_download_url); } catch { continue; }
    const expectedPaths = [companionDistribution.downloadPrefix, companionDistribution.legacyDownloadPrefix]
      .map(prefix => `${prefix}${encodeURIComponent(tag)}/${policy.asset}`);
    if (url.origin !== companionDistribution.downloadOrigin || url.username || url.password
        || !expectedPaths.includes(url.pathname) || url.search || url.hash) continue;
    const comparison = parts.reduce((result, part, i) => result || Math.sign(part - selectedVersion[i]!), 0);
    if (comparison < 0 || (comparison === 0 && priority >= selectedPriority)) continue;
    selected = { product, version, tag, assetURL: url.href, size: asset.size, bundleID: policy.bundleID };
    selectedVersion = parts;
    selectedPriority = priority;
  }
  return selected;
}

/** Failure is different from an empty catalog; callers must retain that distinction. */
export async function fetchCompanionRelease(
  product: CompanionReleaseProduct,
  options: { fetcher?: typeof fetch; signal?: AbortSignal } = {},
): Promise<CompanionRelease | undefined> {
  const fetcher = options.fetcher ?? fetch;
  const releases: unknown[] = [];
  // Bound API work, but fail instead of silently returning an incomplete result.
  for (let page = 1; page <= 100; page++) {
    options.signal?.throwIfAborted();
    const url = new URL(companionDistribution.releasesAPI);
    url.searchParams.set('per_page', '100');
    url.searchParams.set('page', String(page));
    const response = await fetcher(url, {
      signal: options.signal,
      headers: { Accept: 'application/vnd.github+json' },
      redirect: 'error',
    });
    if (!response.ok) throw new Error(`Companion release check failed (HTTP ${response.status}).`);
    const body: unknown = await response.json();
    if (!Array.isArray(body)) throw new Error('Companion release check returned an invalid response.');
    releases.push(...body);
    if (body.length < 100) return selectCompanionRelease(product, releases);
  }
  throw new Error('Companion release catalog exceeds the supported pagination limit.');
}
