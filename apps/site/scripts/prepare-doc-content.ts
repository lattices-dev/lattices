import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { publishedDocs, rewriteDocLinks } from '../src/lib/docs-catalog'
import { publicDocContent } from '../src/lib/doc-access'
import { splitFrontmatter } from '../src/lib/frontmatter'
import { extractHeadings, prepareMarkdown } from '../src/lib/markdown'
import { rewriteDocMarkdown } from '../src/seo/describe'

const site = resolve(import.meta.dir, '..')
const repo = resolve(site, '../..')
const prepared = await Promise.all(publishedDocs.map(async (entry) => {
  const { data, content } = splitFrontmatter(await readFile(resolve(repo, entry.source), 'utf8'))
  const rewrite = (body: string) => rewriteDocMarkdown(prepareMarkdown(rewriteDocLinks(body, entry.source)), typeof data.title === 'string' ? data.title : undefined)
  const rewritten = rewrite(content)
  // Apply the cutoff to source headings, before title normalization can demote
  // a document title to H2 and mistake it for the first detailed section.
  const preview = publicDocContent(content, entry)
  const publicContent = rewrite(preview.content).markdown
  const full = {
    ...entry,
    title: typeof data.title === 'string' ? data.title : rewritten.firstH1 || entry.title,
    description: typeof data.description === 'string' ? data.description : rewritten.summary,
    order: typeof data.order === 'number' ? data.order : 999,
    content: rewritten.markdown,
    headings: extractHeadings(rewritten.markdown),
    gated: false,
  }
  return { full, public: { ...full, content: publicContent, gated: preview.gated, headings: extractHeadings(publicContent) } }
}))
const full = prepared.map((doc) => doc.full)
const publicDocs = prepared.map((doc) => doc.public)
await mkdir(resolve(site, 'src/.generated'), { recursive: true })
await mkdir(resolve(site, '.generated'), { recursive: true })
await writeFile(resolve(site, 'src/.generated/docs.public.json'), JSON.stringify(publicDocs))
// This file is server/build input only. Never import it from src/.
await writeFile(resolve(site, '.generated/docs.private.json'), JSON.stringify(full))
console.log(`Prepared ${full.length} docs; ${publicDocs.filter((doc) => doc.gated).length} have an email cutoff.`)
