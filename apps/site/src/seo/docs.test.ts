import { describe, expect, test } from 'bun:test'
import { docsHome, docsProducts, isCurrentDoc, publishedDocs, resolveDoc } from '../lib/docs-catalog'
import { docMarkdownUrl } from '../lib/doc-markdown-url.mjs'
import { docHeadLinks, docJsonLd, sourceDate } from './docs'

describe('documentation semantic metadata', () => {
  test('keeps every product page, article, breadcrumb, and Markdown representation in its canonical product', () => {
    for (const doc of publishedDocs) {
      const { '@graph': graph } = JSON.parse(docJsonLd(doc, { title: doc.title }))
      const url = `https://lattices.dev${doc.canonicalPath}`
      const page = graph.find((node: { '@id': string }) => node['@id'] === `${url}#webpage`)
      const article = graph.find((node: { '@id': string }) => node['@id'] === `${url}#article`)
      const product = graph.find((node: { '@type': string }) => node['@type'] === 'SoftwareApplication')
      const trail = graph.find((node: { '@type': string }) => node['@type'] === 'BreadcrumbList').itemListElement
      expect(page.url).toBe(url)
      expect(article.mainEntityOfPage['@id']).toBe(page['@id'])
      expect(article.about['@id']).toBe(product['@id'])
      expect(product.name).toBe(docsProducts.find((item) => item.id === doc.product)!.title)
      expect(article.encoding.contentUrl).toBe(`https://lattices.dev${docMarkdownUrl(doc.canonicalPath!)}`)
      expect(trail.at(-1).item).toBe(url)
      expect(trail.map((item: { position: number }) => item.position)).toEqual(trail.map((_: unknown, index: number) => index + 1))
      expect(article['@type']).toBe(isCurrentDoc(doc) ? 'TechArticle' : 'Article')
      expect(article).not.toHaveProperty('datePublished')
      expect(article).not.toHaveProperty('dateModified')
    }
  })

  test('collections list only current pages from their own product, without listing themselves', () => {
    for (const product of docsProducts) {
      const doc = resolveDoc(docsHome(product.id))!
      const { '@graph': graph } = JSON.parse(docJsonLd(doc, { title: doc.title }))
      const collection = graph.find((node: { '@type': string }) => node['@type'] === 'CollectionPage')
      expect(collection.url).toBe(`https://lattices.dev${docsHome(product.id)}/overview`)
      expect(collection.hasPart.map((page: { url: string }) => page.url)).toEqual(
        publishedDocs.filter((entry) => entry.product === product.id && entry.id !== doc.id && isCurrentDoc(entry))
          .map((entry) => `https://lattices.dev${entry.canonicalPath}`),
      )
      expect(graph.filter((node: { '@id': string }) => node['@id'] === collection['@id'])).toHaveLength(1)
    }
  })

  test('old aliases resolve to the same canonical metadata instead of creating duplicate identities', () => {
    const canonical = resolveDoc('/lattices/docs/concepts')!
    const metadata = { title: canonical.title, updatedAt: '2026-10-19T02:03:04-04:00' }
    expect(docJsonLd(resolveDoc('/docs/concepts')!, metadata)).toBe(docJsonLd(canonical, metadata))
    expect(JSON.parse(docJsonLd(canonical, metadata))['@graph'].find((node: { '@type': string }) => node['@type'] === 'TechArticle').dateModified).toBe(metadata.updatedAt)
  })

  test('does not invent or normalize unknown source dates', () => {
    for (const invalid of [undefined, null, '', 'today', '2026', '2026-02-30', '2026-10-19T12:00:00', '2026-13-19T12:00:00Z']) {
      expect(sourceDate(invalid)).toBeUndefined()
    }
    expect(sourceDate('2024-02-29')).toBe('2024-02-29')
    expect(sourceDate('2026-10-19T04:00:00Z')).toBe('2026-10-19T04:00:00Z')
  })

  test('Canvas documentation aliases share canonical product and article identities', () => {
    const doc = resolveDoc('/canvas/docs/agents')!
    expect(doc.product).toBe('blink')
    expect(docJsonLd(resolveDoc('/blink/docs/agents')!, { title: doc.title })).toBe(docJsonLd(doc, { title: doc.title }))
    const { '@graph': graph } = JSON.parse(docJsonLd(doc, { title: doc.title }))
    const product = graph.find((node: { '@type': string }) => node['@type'] === 'SoftwareApplication')
    expect(product).toMatchObject({ name: 'Canvas', url: 'https://lattices.dev/canvas', '@id': 'https://lattices.dev/canvas#software' })
    expect(JSON.stringify(graph)).not.toContain('/blink')
    expect(docHeadLinks(doc).every((link) => link.href.startsWith('/canvas/docs/'))).toBe(true)
  })

  test('only the exact document is an alternate and product indexes describe the document', () => {
    for (const doc of publishedDocs) {
      const links = docHeadLinks(doc)
      expect(links.filter((link) => link.rel === 'alternate')).toEqual([
        { rel: 'alternate', type: 'text/markdown', href: docMarkdownUrl(doc.canonicalPath!), title: `${doc.title} — Markdown` },
      ])
      expect(links.filter((link) => link.rel === 'describedby').map((link) => link.href)).toEqual([
        `${docsHome(doc.product)}/llms.txt`, `${docsHome(doc.product)}/agent-docs.json`, `${docsHome(doc.product)}/AGENTS.md`,
      ])
    }
  })

  test('keeps agent guide Markdown distinct from public AGENTS instructions on case-insensitive filesystems', () => {
    const guides = publishedDocs.filter((doc) => /\/agents$/i.test(doc.canonicalPath!))
    expect(guides.length).toBeGreaterThan(0)
    for (const doc of guides) {
      const alternate = docHeadLinks(doc).find((link) => link.rel === 'alternate')!
      const instructions = docHeadLinks(doc).find((link) => link.href.endsWith('/AGENTS.md'))!
      expect(alternate.href).toBe(`${doc.canonicalPath}/index.md`)
      expect(alternate.href.toLowerCase()).not.toBe(instructions.href.toLowerCase())
      const { '@graph': graph } = JSON.parse(docJsonLd(doc, { title: doc.title }))
      expect(graph.find((node: { '@type': string }) => node['@type'] === 'TechArticle').encoding.contentUrl).toBe(`https://lattices.dev${alternate.href}`)
    }
    expect(docMarkdownUrl('/lattices/docs/AgEnTs')).toBe('/lattices/docs/AgEnTs/index.md')
    expect(docMarkdownUrl('/lattices/docs/concepts')).toBe('/lattices/docs/concepts.md')
  })

  test('escapes script delimiters without corrupting authored titles', () => {
    const doc = resolveDoc('/action/docs/overview')!
    const title = '</script><script>alert("unexpected")</script>'
    const json = docJsonLd(doc, { title })
    expect(json).not.toContain('<')
    expect(JSON.parse(json)['@graph'].find((node: { '@type': string }) => node['@type'] === 'TechArticle').headline).toBe(title)
  })
})
