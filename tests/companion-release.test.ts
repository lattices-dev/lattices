import { describe, expect, test } from 'bun:test';
import { fetchCompanionRelease, selectCompanionRelease } from '../bin/companion-release';

function release(tag = 'blink-v2.0.0', asset = 'Blink.dmg', repository = 'lattices-dev/lattices') {
  return { tag_name: tag, draft: false, prerelease: false, assets: [{
    name: asset, state: 'uploaded', size: 1000,
    browser_download_url: `https://github.com/${repository}/releases/download/${tag}/${asset}`,
  }] };
}

describe('companion release policy', () => {
  test('accepts exact release assets before and after the repository transfer', () => {
    for (const repository of ['arach/lattices', 'lattices-dev/lattices']) {
      expect(selectCompanionRelease('blink', [release('blink-v2.0.0', 'Blink.dmg', repository)])?.version).toBe('2.0.0');
    }
    for (const repository of ['lattices-dev/other', 'other/lattices', 'lattices-dev/lattices-copy']) {
      expect(selectCompanionRelease('blink', [release('blink-v2.0.0', 'Blink.dmg', repository)])).toBeUndefined();
    }
  });
  test('selects the highest stable product version independent of API order', () => {
    const result = selectCompanionRelease('blink', [
      release('v99.0.0'), release('blink-v2.9.0'), release('blink-v2.10.0'),
      release('action-v9.0.0', 'Action.dmg'), release('blink-v2.1.0'),
    ]);
    expect(result?.version).toBe('2.10.0');
    expect(result?.bundleID).toBe('dev.arach.blink');
  });
  test('resolves each companion using its own namespace and identity', () => {
    const entries = [release(), release('action-v1.0.0', 'Action.dmg'), release('speech-v1.0.0', 'Speech.dmg')];
    expect(selectCompanionRelease('action', entries)?.bundleID).toBe('dev.lattices.Action');
    expect(selectCompanionRelease('speech', entries)?.bundleID).toBe('dev.lattices.Speech');
    expect(selectCompanionRelease('speech', [release()])).toBeUndefined();
  });
  test('rejects draft, prerelease, malformed version and missing assets', () => {
    expect(selectCompanionRelease('blink', [
      { ...release(), draft: true }, { ...release(), prerelease: true },
      release('blink-v02.0.0'), release('blink-v3.0.0-beta'),
      release('blink-v4.0.0', 'Lattices.dmg'),
    ])).toBeUndefined();
  });
  test('requires an exact trusted asset path and uploaded nonempty artifact', () => {
    for (const patch of [
      { browser_download_url: 'https://evil.example/Blink.dmg' },
      { browser_download_url: 'https://github.com/arach/other/releases/download/blink-v2.0.0/Blink.dmg' },
      { size: 0 }, { size: 3 * 1024 ** 3 }, { state: 'new' },
    ]) {
      const entry = release(); Object.assign(entry.assets[0]!, patch);
      expect(selectCompanionRelease('blink', [entry])).toBeUndefined();
    }
  });
  test('rejects ambiguous duplicate assets', () => {
    const entry = release(); entry.assets.push(entry.assets[0]!);
    expect(selectCompanionRelease('blink', [entry])).toBeUndefined();
  });
  test('paginates before choosing and supports cancellation', async () => {
    const urls: string[] = [];
    const fetcher = (async (input: URL | RequestInfo) => {
      urls.push(String(input));
      return Response.json(urls.length === 1 ? Array(100).fill(release('v1.0.0')) : [release()]);
    }) as typeof fetch;
    expect((await fetchCompanionRelease('blink', { fetcher }))?.version).toBe('2.0.0');
    expect(urls[1]).toContain('page=2');
    expect(urls[0]).toStartWith('https://api.github.com/repositories/1171006654/releases?');
    const abort = new AbortController(); abort.abort();
    await expect(fetchCompanionRelease('blink', { fetcher, signal: abort.signal })).rejects.toThrow();
    expect(urls.length).toBe(2);
  });
  test('distinguishes absent releases from transport or schema failure', async () => {
    const fetcher = (async () => Response.json([])) as typeof fetch;
    expect(await fetchCompanionRelease('action', { fetcher })).toBeUndefined();
    await expect(fetchCompanionRelease('action', {
      fetcher: (async () => new Response('', { status: 403 })) as typeof fetch,
    })).rejects.toThrow('HTTP 403');
    await expect(fetchCompanionRelease('action', {
      fetcher: (async () => Response.json({ message: 'bad' })) as typeof fetch,
    })).rejects.toThrow('invalid response');
  });
});
