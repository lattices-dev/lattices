import catalog from '../data/docs-catalog.json'

export type ProductId = 'lattices' | 'action' | 'blink' | 'speech'
export type DocKind = 'guide' | 'reference' | 'proposal' | 'history' | 'prompt'
export interface DocEntry {
  id: string
  product: ProductId
  slug: string
  source: string
  title: string
  kind: DocKind
  canonicalPath: string | null
  aliases: string[]
  navGroup: string | null
  agent: boolean
  rawAliases: string[]
}
export interface ProductAgentStart {
  /** Canonical page for the product's agent guide. */
  guide: string
  /** One read-only command that proves the runtime answers. */
  firstCheck: string
  expect: string
  boundary: string
}
export interface DocsProduct {
  id: ProductId
  title: string
  description: string
  home: string
  /** Public documentation root; independent of the runtime/source product ID. */
  docsHome: string
  agent: ProductAgentStart
}
export interface NavGroup {
  id: string
  title: string
  items: { id: string; title: string; href: string }[]
}

export const docsProducts = catalog.products as DocsProduct[]
export const docCatalog = catalog.pages as DocEntry[]
export const publishedDocs = docCatalog.filter((page) => page.canonicalPath)
export const isCurrentDoc = (page: DocEntry) => page.kind === 'guide' || page.kind === 'reference'
export const docsProduct = (id: ProductId) => docsProducts.find((product) => product.id === id)!
export const docsHome = (id: ProductId) => docsProduct(id).docsHome
/** Raw Markdown for one page, and the product-scoped agent bundles the site build writes. */
export const docRawUrl = (entry: DocEntry) => `${docsHome(entry.product)}/markdown/${isCurrentDoc(entry) ? '' : 'archive/'}${entry.slug}.md`
export const productAgentUrls = (id: ProductId) => ({
  index: `${docsHome(id)}/llms.txt`,
  full: `${docsHome(id)}/llms-full.txt`,
  json: `${docsHome(id)}/agent-docs.json`,
})
export const docEditUrl = (entry: DocEntry) => `https://github.com/lattices-dev/lattices/edit/main/${entry.source}`

export function resolveDoc(path: string): DocEntry | undefined {
  const normalized = path.replace(/\/+$/, '')
  return publishedDocs.find((page) => page.canonicalPath === normalized || page.aliases.includes(normalized))
}

export function productNav(product: ProductId): NavGroup[] {
  const groups = new Map<string, NavGroup>()
  for (const page of publishedDocs) {
    if (page.product !== product || !page.navGroup || !isCurrentDoc(page)) continue
    if (!groups.has(page.navGroup)) groups.set(page.navGroup, { id: page.navGroup, title: page.navGroup, items: [] })
    groups.get(page.navGroup)!.items.push({ id: page.slug, title: page.title, href: page.canonicalPath! })
  }
  return [...groups.values()]
}

/** Resolve authored links against source ownership, independent of the page's new URL. */
export function docLink(href: string, source: string): string {
  if (!href || /^(#|mailto:|tel:|data:)/.test(href)) return href
  if (/^https?:/.test(href)) {
    const url = new URL(href)
    if (url.origin !== 'https://lattices.dev') return href
    return docLink(url.pathname + url.search + url.hash, source)
  }
  if (href.startsWith('//')) return href
  const match = href.match(/^([^?#]*)(.*)$/)!
  const [, pathname, suffix] = match
  if (pathname.startsWith('/')) {
    return (resolveDoc(pathname)?.canonicalPath || pathname) + suffix
  }
  const segments = source.split('/').slice(0, -1)
  for (const part of pathname.split('/')) {
    if (part === '..') segments.pop()
    else if (part && part !== '.') segments.push(part)
  }
  const target = segments.join('/')
  const entry = docCatalog.find((page) => page.source === target)
  if (entry) return (entry.canonicalPath || docRawUrl(entry)) + suffix
  if (target.startsWith('docs/assets/')) return `/${target}${suffix}`
  if (target.startsWith('products/action/docs/assets/')) return `/action/media/${target.slice('products/action/docs/assets/'.length)}${suffix}`
  return `https://github.com/lattices-dev/lattices/blob/main/${target}${suffix}`
}

/** Rewrite prose links only; command samples retain their exact bytes. */
export function rewriteDocLinks(markdown: string, source: string): string {
  let fence: string | null = null
  return markdown.split('\n').map((line) => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/)?.[1]
    if (marker) {
      if (!fence) fence = marker
      else if (marker[0] === fence[0] && marker.length >= fence.length) fence = null
      return line
    }
    if (fence) return line
    return line
      .replace(/(!?\[[^\]]*\]\()([^\s)]+)([^)]*\))/g, (_, before, url, after) => `${before}${docLink(url, source)}${after}`)
      .replace(/^(\s*\[[^\]]+\]:\s*)(\S+)/, (_, before, url) => `${before}${docLink(url, source)}`)
      .replace(/\b(href|src)="([^"\s]+)"/g, (_, attr, url) => `${attr}="${docLink(url, source)}"`)
  }).join('\n')
}
