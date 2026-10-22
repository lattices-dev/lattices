import { describe, expect, test } from 'bun:test'
import { existsSync, readdirSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import {
  docCatalog, docLink, docRawUrl, docsHome, docsProduct, docsProducts, isCurrentDoc,
  productAgentUrls, productNav, publishedDocs, resolveDoc, rewriteDocLinks,
} from '../src/lib/docs-catalog'

const repoRoot = resolve(import.meta.dir, '../../..')

function markdownFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name)
    return entry.isDirectory() ? markdownFiles(path) : entry.name.endsWith('.md') ? [relative(repoRoot, path)] : []
  })
}

describe('product documentation catalog', () => {
  test('assigns every repository document exactly one source owner', () => {
    const sources = docCatalog.map((page) => page.source)
    expect(new Set(sources).size).toBe(sources.length)
    expect(new Set(docCatalog.map((page) => page.id)).size).toBe(docCatalog.length)
    for (const directory of ['docs', 'products/action/docs', 'products/blink/docs', 'products/voice/docs']) {
      for (const source of markdownFiles(join(repoRoot, directory))) {
        expect(sources, `Unmapped source: ${source}`).toContain(source)
      }
    }
    for (const source of sources) expect(existsSync(join(repoRoot, source)), `Missing source: ${source}`).toBe(true)
  })

  test('has unique canonical and alias routes within each owning product', () => {
    const owners = new Map<string, string>()
    for (const page of publishedDocs) {
      expect(page.canonicalPath).toStartWith(`${docsHome(page.product)}/`)
      for (const path of [page.canonicalPath!, ...page.aliases]) {
        expect(owners.has(path), `Duplicate HTML route: ${path}`).toBe(false)
        owners.set(path, page.id)
        expect(resolveDoc(path)?.id).toBe(page.id)
        expect(resolveDoc(`${path}/`)?.id).toBe(page.id)
      }
    }
    for (const product of docsProducts) {
      expect(resolveDoc(docsHome(product.id))?.id).toBe(`${product.id}:overview`)
    }
    expect(resolveDoc('/docs')?.canonicalPath).toBe('/lattices/docs/overview')
    expect(resolveDoc('/lattices/docs/not-a-page')).toBeUndefined()
  })

  test('preserves the original top-level docs page URLs, including archived pages', () => {
    const original = markdownFiles(join(repoRoot, 'docs')).filter((source) => source.split('/').length === 2)
    for (const source of original) {
      const oldPath = `/docs/${source.slice('docs/'.length, -'.md'.length)}`
      expect(resolveDoc(oldPath)?.source, oldPath).toBe(source)
    }
  })

  test('publishes Canvas URLs while retaining Blink runtime identity and every legacy docs path', () => {
    const canvas = docsProduct('blink')
    expect(canvas.title).toBe('Canvas')
    expect(canvas.home).toBe('/canvas')
    expect(docsHome(canvas.id)).toBe('/canvas/docs')
    expect(canvas.agent.guide).toBe('/canvas/docs/agents')
    expect(canvas.agent.firstCheck).toBe('blink ls --json')
    expect(canvas.agent.expect).toContain('BLINK_HOME')
    expect(productAgentUrls(canvas.id)).toEqual({
      index: '/canvas/docs/llms.txt', full: '/canvas/docs/llms-full.txt', json: '/canvas/docs/agent-docs.json',
    })
    expect(resolveDoc('/blink/docs')).toBe(resolveDoc('/canvas/docs'))
    for (const page of docCatalog.filter((entry) => entry.product === canvas.id)) {
      expect(page.source).toStartWith('products/blink/')
      const rawPath = docRawUrl(page)
      expect(rawPath).toStartWith('/canvas/docs/markdown/')
      expect(page.rawAliases).toContain(rawPath.replace('/canvas/', '/blink/'))
      if (page.canonicalPath) {
        expect(resolveDoc(page.canonicalPath.replace('/canvas/', '/blink/'))).toBe(page)
        expect(productNav(canvas.id).flatMap((group) => group.items).every((item) => item.href.startsWith('/canvas/docs/'))).toBe(true)
      }
    }
    expect(docLink('/blink/docs/cli#flags', 'docs/overview.md')).toBe('/canvas/docs/cli#flags')
    expect(docLink('../products/blink/docs/api.md', 'docs/overview.md')).toBe('/canvas/docs/api')
  })

  test('gives raw artifacts unique owners and keeps the maintained Action overrides authoritative', () => {
    const owners = new Map<string, string>()
    const htmlPaths = new Set(publishedDocs.flatMap((page) => [page.canonicalPath!, ...page.aliases]))
    for (const page of docCatalog) {
      const rawPath = docRawUrl(page)
      for (const path of [rawPath, ...page.rawAliases]) {
        expect(path.endsWith('.md'), path).toBe(true)
        expect(htmlPaths.has(path), `Raw path replaced with HTML: ${path}`).toBe(false)
        expect(owners.has(path), `Duplicate raw route: ${path}`).toBe(false)
        owners.set(path, page.source)
      }
    }
    expect(owners.get('/action/remote-engine.md')).toBe('apps/site/content/action/remote-engine.md')
    expect(owners.get('/action/agent-setup.md')).toBe('apps/site/content/action/agent-setup.md')
    expect(owners.get('/blink/agents.md')).toBe('products/blink/landing/public/agents.md')
  })

  test('shows only current documents from the selected product in its navigation', () => {
    for (const product of docsProducts) {
      const groups = productNav(product.id)
      expect(groups.length).toBeGreaterThan(0)
      const actualIds = groups.flatMap((group) => group.items.map((item) => {
        const page = resolveDoc(item.href)!
        expect(page.product).toBe(product.id)
        expect(isCurrentDoc(page)).toBe(true)
        expect(page.navGroup).toBe(group.title)
        return page.id
      }))
      const expectedIds = publishedDocs.filter((page) => page.product === product.id && page.navGroup && isCurrentDoc(page)).map((page) => page.id)
      expect(actualIds).toEqual(expectedIds)
    }
    for (const page of docCatalog.filter((page) => !isCurrentDoc(page))) {
      expect(page.agent, `Historical page in current agent context: ${page.id}`).toBe(false)
      expect(page.navGroup, `Historical page in navigation: ${page.id}`).toBeNull()
    }
  })
})

describe('source-aware documentation links', () => {
  test('resolves same-product and cross-product source links while retaining query and fragment', () => {
    expect(docLink('./api.md#methods', 'products/action/docs/overview.md')).toBe('/action/docs/api#methods')
    expect(docLink('../../../docs/mcp.md?format=html#tools', 'products/action/docs/overview.md')).toBe('/lattices/docs/mcp?format=html#tools')
    expect(docLink('../products/voice/docs/api.md#protocol', 'docs/overview.md')).toBe('/voice/docs/api#protocol')
    expect(docLink('./agent-api.md', 'products/blink/docs/overview.md')).toBe('/canvas/docs/markdown/archive/agent-api.md')
    expect(docLink('https://lattices.dev/docs/api#calls', 'products/action/docs/overview.md')).toBe('/lattices/docs/api#calls')
    expect(docLink('/docs/concepts?diagram=1#runtime', 'products/action/docs/overview.md')).toBe('/lattices/docs/concepts?diagram=1#runtime')
  })

  test('leaves external links, explicit raw references and local fragments intact', () => {
    for (const href of ['https://example.org/docs/api.md#calls', '//example.org/api.md', '#runtime', 'mailto:help@example.org', 'tel:+12345', '/action/api.md', '/docs/markdown/api.md']) {
      expect(docLink(href, 'docs/overview.md')).toBe(href)
    }
    expect(docLink('./assets/action-record-the-work.mp4', 'products/action/docs/recording.md')).toBe('/action/media/action-record-the-work.mp4')
  })

  test('rewrites prose and reference links without changing fenced command examples', () => {
    const markdown = '[API](api.md#methods)\n[api]: api.md\n<a href="api.md">API</a>\n\n````md\n[API](api.md)\n```\n<a href="api.md">sample</a>\n````\n\n~~~sh\necho "[API](api.md)"\n~~~\n'
    const expected = markdown
      .replace('[API](api.md#methods)', '[API](/action/docs/api#methods)')
      .replace('[api]: api.md', '[api]: /action/docs/api')
      .replace('<a href="api.md">API</a>', '<a href="/action/docs/api">API</a>')
    expect(rewriteDocLinks(markdown, 'products/action/docs/overview.md')).toBe(expected)
  })
})
