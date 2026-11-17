import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { publicDocContent } from '../src/lib/doc-access'
import { splitFrontmatter } from '../src/lib/frontmatter'
import { docMarkdownUrl } from '../src/lib/doc-markdown-url.mjs'

/** Split delivery before search indexing or publishing the static directory. */
export async function packageAccess({ siteDir, distDir, artifactPaths }: { siteDir: string; distDir: string; artifactPaths: string[] }) {
  const repo = resolve(siteDir, '../..')
  const privateDir = join(siteDir, 'private-dist')
  const paths: { artifacts: Record<string, string>; docs: Record<string, string> } = { artifacts: {}, docs: {} }
  const catalog = JSON.parse(await readFile(join(siteDir, 'src/data/docs-catalog.json'), 'utf8'))
  const fullDocs = JSON.parse(await readFile(join(siteDir, '.generated/docs.private.json'), 'utf8'))
  const previews = new Map<string, string>()
  for (const entry of catalog.pages) {
    const raw = await readFile(join(repo, entry.source), 'utf8')
    const parsed = splitFrontmatter(raw)
    const preview = publicDocContent(parsed.content, entry)
    const body = `${preview.content}${preview.gated ? '\n\nContinue with free email access at ' + (entry.canonicalPath || '/docs') + '.\n' : '\n'}`
    const product = catalog.products.find((item: { id: string }) => item.id === entry.product)
    const root = product.docsHome
    const archive = ['guide', 'reference'].includes(entry.kind) ? '' : 'archive/'
    for (const path of [
      `${root}/markdown/${archive}${entry.slug}.md`,
      ...entry.rawAliases,
      ...(entry.canonicalPath ? [entry.canonicalPath, ...entry.aliases].flatMap((route: string) => [docMarkdownUrl(route), `${route}/index.md`]) : []),
    ]) previews.set(path, body)
  }
  const files = new Set(artifactPaths)
  // Legacy copied Action references bypass the catalog writer; include them too.
  async function walk(folder: string, prefix = ''): Promise<string[]> {
    const result: string[] = []
    for (const entry of await readdir(folder, { withFileTypes: true })) {
      const path = `${prefix}/${entry.name}`
      if (entry.isDirectory()) result.push(...await walk(join(folder, entry.name), path))
      else result.push(path)
    }
    return result
  }
  for (const path of await walk(join(distDir, 'action'), '/action')) {
    if (!path.startsWith('/action/media/') && /\.(md|json|txt)$/.test(path)) files.add(path)
  }
  for (const path of await walk(join(distDir, '.well-known'), '/.well-known')) files.add(path)
  for (const path of ['/blink/agents.md', '/blink/llms.txt', '/action/agents/index.html']) files.add(path)
  const viteManifest = JSON.parse(await readFile(join(distDir, '.vite/manifest.json'), 'utf8'))
  const studyChunk = viteManifest['src/components/ConceptExperimentPage.tsx']?.file
  if (!studyChunk) throw new Error('Study must have a separately protected JavaScript chunk')
  files.add(`/${studyChunk}`)
  for (const path of files) {
    if (path === '/.nojekyll') continue
    const source = join(distDir, path)
    let bytes: Buffer
    try { bytes = await readFile(source) } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue; throw error }
    const target = join(privateDir, path)
    await mkdir(dirname(target), { recursive: true })
    await writeFile(target, bytes)
    paths.artifacts[path] = path.slice(1)
    // Metadata discovery is intentionally replaced with an honest access marker;
    // full bundles and raw references remain available after the cookie check.
    const preview = previews.get(path)
    const notice = { access: 'email-code', message: 'Detailed documentation requires a free emailed access code.', url: '/docs' }
    const publicBody = preview || (path.endsWith('.js') ? 'throw new Error("Enter your Lattices access code before opening this study.");\n' : path.endsWith('.json') ? JSON.stringify(notice) + '\n' : path.endsWith('.html')
      ? '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Continue reading — Lattices</title><main><h1>Continue with Lattices</h1><p>Detailed agent guides are available with free email access.</p><a href="/action/docs/agents">Get your access code</a></main></html>'
      : '# Lattices documentation\n\nDetailed guides and studies are available with free email access.\n\nContinue at /docs.\n')
    // Installation remains usable even by tools without browser cookies.
    if (path === '/action/install.md') { delete paths.artifacts[path]; continue }
    await writeFile(source, publicBody)
  }
  for (const doc of fullDocs) {
    const path = `docs/${doc.id.replace(':', '/')}.json`
    await mkdir(dirname(join(privateDir, path)), { recursive: true })
    await writeFile(join(privateDir, path), JSON.stringify(doc))
    paths.docs[doc.id] = path
  }
  await writeFile(join(siteDir, '.generated/protected-paths.json'), JSON.stringify(paths))
  console.log(`Separated ${Object.keys(paths.artifacts).length} detailed artifacts from public delivery.`)
}
