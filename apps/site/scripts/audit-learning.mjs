import assert from 'node:assert/strict'
import { access, readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { competitors, guides, learningRoutes, videoAssets, videos } from '../src/lib/learning.ts'

const dist = resolve(import.meta.dirname, '../dist')
const sitemap = await readFile(join(dist, 'sitemap.xml'), 'utf8')
const paths = new Set(learningRoutes.map(route => route.path))
assert.equal(paths.size, learningRoutes.length, 'Duplicate learning routes')
const titles = new Set()
const descriptions = new Set()
let checkedLinks = 0

for (const route of learningRoutes) {
  const html = await readFile(join(dist, route.path, 'index.html'), 'utf8')
  assert.equal((html.match(/<h1(?:\s|>)/g) || []).length, 1, `${route.path}: one H1`)
  assert(html.includes('data-pagefind-body'), `${route.path}: searchable body`)
  assert(html.includes(`<link rel="canonical" href="https://lattices.dev${route.path}"`), `${route.path}: canonical`)
  assert(sitemap.includes(`<loc>https://lattices.dev${route.path}</loc>`), `${route.path}: sitemap`)
  assert(!html.includes('name="robots" content="noindex"'), `${route.path}: indexability`)
  const title = html.match(/<title>(.*?)<\/title>/s)?.[1]
  const description = html.match(/<meta name="description" content="(.*?)"/s)?.[1]
  assert(title && !titles.has(title), `${route.path}: unique title`)
  assert(description && !descriptions.has(description), `${route.path}: unique description`)
  titles.add(title)
  descriptions.add(description)
  const schemas = [...html.matchAll(/<script type="application\/ld\+json">(.*?)<\/script>/gs)].map(match => JSON.parse(match[1]))
  assert(schemas.some(schema => schema['@graph']?.some(node => node['@type'] === 'BreadcrumbList')), `${route.path}: breadcrumbs`)
  for (const match of html.matchAll(/(?:href|src)="(\/(?:learn|compare|watch)[^"?#]*)/g)) {
    const target = match[1]
    await access(join(dist, target, target.includes('.') ? '' : 'index.html'))
    checkedLinks++
  }
}
for (const item of [...guides, ...competitors, ...videos]) {
  assert(item.sources.length >= 2, `${item.slug}: at least two sources`)
  for (const source of item.sources) {
    if (source.url.startsWith('/docs/')) {
      const [pathname, fragment] = source.url.split('#')
      const sourceHTML = await readFile(join(dist, pathname, 'index.html'), 'utf8')
      if (fragment) assert(sourceHTML.includes(`id="${fragment}"`), `${item.slug}: source anchor ${source.url}`)
    } else {
      assert(new URL(source.url).protocol === 'https:', `${item.slug}: HTTPS source`)
    }
  }
}
const seconds = timestamp => timestamp.split(':').reduce((sum, part) => sum * 60 + Number(part), 0)
for (const video of videos) {
  const asset = videoAssets[video.slug]
  assert(asset.durationSeconds > 0 && asset.width > 0 && asset.height > 0, `${video.slug}: measured media metadata`)
  const watchHTML = await readFile(join(dist, 'watch', video.slug, 'index.html'), 'utf8')
  assert(watchHTML.includes('Read the visual transcript') && watchHTML.includes('On-screen diagram labels'), `${video.slug}: static full transcript`)
  assert(!asset.fullTranscript.includes('lattices.app'), `${video.slug}: canonical domain in transcript`)
  const vtt = await readFile(join(dist, 'learn/media', `${video.slug}.vtt`), 'utf8')
  assert(vtt.startsWith('WEBVTT') && vtt.includes('-->'), `${video.slug}: captions`)
  const cues = vtt.trim().split(/\n\s*\n/).slice(1).map(block => {
    const lines = block.split('\n')
    const timingIndex = lines.findIndex(line => line.includes(' --> '))
    assert(timingIndex >= 0, `${video.slug}: cue timing`)
    const [start, end] = lines[timingIndex].split(' --> ')
    return { start: seconds(start), end: seconds(end), text: lines.slice(timingIndex + 1).join(' ') }
  })
  assert.deepEqual(cues, asset.transcript, `${video.slug}: caption/manifest consistency`)
  for (const [index, cue] of cues.entries()) {
    assert(Number.isFinite(cue.start) && Number.isFinite(cue.end) && cue.end > cue.start, `${video.slug}: positive cue duration`)
    assert(cue.start >= (cues[index - 1]?.end ?? 0) && cue.end <= asset.durationSeconds, `${video.slug}: cue within media timeline`)
    assert(cue.text.trim(), `${video.slug}: nonempty caption`)
  }
  const fullTranscript = await readFile(join(dist, 'learn/media', `${video.slug}-transcript.txt`), 'utf8')
  assert.equal(fullTranscript, asset.fullTranscript, `${video.slug}: full transcript/manifest consistency`)
  for (const suffix of ['.mp4', '-poster.jpg', '-transcript.txt']) await access(join(dist, 'learn/media', `${video.slug}${suffix}`))
}
console.log(`Learning audit passed: ${learningRoutes.length} static routes, ${checkedLinks} internal content/media links, ${competitors.length} comparisons, ${guides.length} lessons, ${videos.length} captioned videos.`)
