import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = path.dirname(fileURLToPath(import.meta.url));
const media = path.resolve(root, '../../apps/site/public/learn/media');
const evidence = path.join(root, 'evidence');
fs.mkdirSync(evidence, { recursive: true });
const time = value => value.split(':').reduce((total, part) => total * 60 + Number(part), 0);
// A batch refresh must preserve clips produced by later batches.
const manifestPath = path.join(media, 'manifest.json');
const manifest = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath, 'utf8')) : {};
for (const [slug, posterSecond] of [['ax-tree', 24], ['ax-vs-screenshots', 23]]) {
  const video = path.join(media, `${slug}.mp4`);
  const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_format', '-show_streams', '-of', 'json', video], { encoding: 'utf8' }));
  const stream = probe.streams.find(item => item.codec_type === 'video');
  if (!stream || Number(probe.format.duration) < 35.9) throw new Error(`Incomplete video: ${slug}`);
  const transcript = fs.readFileSync(path.join(media, `${slug}.vtt`), 'utf8').trim().split(/\n\s*\n/).slice(1).map(block => {
    const lines = block.split('\n');
    const timingIndex = lines.findIndex(line => line.includes(' --> '));
    const [start, end] = lines[timingIndex].split(' --> ');
    return { start: time(start), end: time(end), text: lines.slice(timingIndex + 1).join(' ') };
  });
  manifest[slug] = { durationSeconds: Number(probe.format.duration), width: stream.width, height: stream.height, transcript, fullTranscript: fs.readFileSync(path.join(media, `${slug}-transcript.txt`), 'utf8') };
  execFileSync('ffmpeg', ['-y', '-hide_banner', '-loglevel', 'error', '-ss', String(posterSecond), '-i', video, '-frames:v', '1', '-q:v', '2', path.join(media, `${slug}-poster.jpg`)]);
  fs.writeFileSync(path.join(evidence, `${slug}-ffprobe.json`), JSON.stringify(probe, null, 2) + '\n');
}
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
console.log(`Refreshed the first two clips; manifest contains ${Object.keys(manifest).length} clips.`);
