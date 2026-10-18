import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const media = path.resolve(root, '../../apps/site/public/learn/media');
const manifestPath = path.join(media, 'manifest.json');
const inputs = process.argv.slice(2);
assert(inputs.length, 'Usage: node studies/seo-explainers/merge-manifests.mjs <batch-manifest.json> [...]');

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const imported = new Set();
for (const input of inputs) {
  const batch = JSON.parse(fs.readFileSync(path.resolve(input), 'utf8'));
  for (const [slug, asset] of Object.entries(batch)) {
    assert(/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug), `Invalid media slug: ${slug}`);
    assert(!imported.has(slug), `Duplicate clip in input batches: ${slug}`);
    assert(Number.isFinite(asset.durationSeconds) && asset.durationSeconds > 0, `${slug}: measured duration required`);
    assert(Number.isInteger(asset.width) && asset.width > 0 && Number.isInteger(asset.height) && asset.height > 0, `${slug}: measured dimensions required`);
    assert(Array.isArray(asset.transcript) && asset.transcript.length > 0, `${slug}: caption cues required`);
    for (const suffix of ['.mp4', '-poster.jpg', '.vtt', '-transcript.txt']) {
      assert(fs.statSync(path.join(media, `${slug}${suffix}`)).size > 0, `${slug}${suffix}: nonempty media required`);
    }
    assert.equal(asset.fullTranscript, fs.readFileSync(path.join(media, `${slug}-transcript.txt`), 'utf8'), `${slug}: transcript differs from exported file`);
    manifest[slug] = asset;
    imported.add(slug);
  }
}
// Validate the whole batch before replacing the shared manifest.
const temporary = `${manifestPath}.tmp`;
fs.writeFileSync(temporary, JSON.stringify(manifest, null, 2) + '\n');
fs.renameSync(temporary, manifestPath);
console.log(`Imported ${imported.size} clips; shared manifest contains ${Object.keys(manifest).length}.`);
