import { readdir, readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'

const site = resolve(import.meta.dir, '..')
const publicFiles: string[] = []
async function walk(folder: string) {
  for (const entry of await readdir(folder, { withFileTypes: true })) {
    const path = join(folder, entry.name)
    if (entry.name === '__private') throw new Error('Private directory found in static dist')
    if (entry.isDirectory()) await walk(path)
    else if (/\.(html|js|json|txt|md)$/.test(entry.name)) publicFiles.push(path)
  }
}
await walk(join(site, 'dist'))
const publicText = (await Promise.all(publicFiles.map((path) => readFile(path, 'utf8')))).join('\n')
const docs = JSON.parse(await readFile(join(site, '.generated/docs.private.json'), 'utf8'))
const previews = JSON.parse(await readFile(join(site, 'src/.generated/docs.public.json'), 'utf8'))
const blogDir = join(site, 'content/blog')
const publicBlogs = await Promise.all((await readdir(blogDir)).filter((name) => /\.(md|mdx)$/.test(name)).map((name) => readFile(join(blogDir, name), 'utf8')))
const allowedPublicContent = [...previews.map((doc: { content: string }) => doc.content), ...publicBlogs].join('\n')
let checked = 0
for (const doc of docs) {
  const preview = previews.find((item: { id: string }) => item.id === doc.id)
  if (!preview.gated) continue
  // Long, exact spans from beyond each cutoff must not survive in any HTML,
  // client JS, raw reference or JSON. Search-index source is the same public HTML.
  const candidates = doc.content.split(/\n\s*\n/).filter((part: string) => part.length >= 100 && !allowedPublicContent.includes(part))
  for (const candidate of candidates) {
    if (publicText.includes(candidate) || publicText.includes(JSON.stringify(candidate).slice(1, -1))) {
      for (const path of publicFiles) {
        const text = await readFile(path, 'utf8')
        if (text.includes(candidate) || text.includes(JSON.stringify(candidate).slice(1, -1))) throw new Error(`Detailed content leaked to public output: ${doc.id} in ${path}; ${candidate.slice(0, 160)}`)
      }
    }
  }
  checked++
}
const manifest = JSON.parse(await readFile(join(site, '.generated/protected-paths.json'), 'utf8'))
const study = Object.keys(manifest.artifacts).find((path) => path.includes('ConceptExperimentPage-') && path.endsWith('.js'))
if (!study || !(await readFile(join(site, 'dist', study), 'utf8')).startsWith('throw new Error')) throw new Error('Study JavaScript is publicly readable')
console.log(`Public output checked: ${checked} cutoffs; study chunk protected; no private directory.`)
