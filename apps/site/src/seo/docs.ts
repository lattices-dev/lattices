import {
  docsHome, docsProduct, isCurrentDoc, productAgentUrls, publishedDocs,
  type DocEntry,
} from '../lib/docs-catalog'
import { docMarkdownUrl } from '../lib/doc-markdown-url.mjs'
import { absoluteUrl, SITE_ORIGIN } from './routes'

export interface DocHeadLink {
  rel: 'alternate' | 'describedby'
  type: string
  href: string
  title: string
}

/** Only the page's Markdown is an alternate representation of that page. */
export function docHeadLinks(doc: DocEntry): DocHeadLink[] {
  if (!doc.canonicalPath) throw new Error(`Cannot describe an unpublished document: ${doc.id}`)
  const product = docsProduct(doc.product)
  const artifacts = productAgentUrls(doc.product)
  return [
    { rel: 'alternate', type: 'text/markdown', href: docMarkdownUrl(doc.canonicalPath), title: `${doc.title} — Markdown` },
    { rel: 'describedby', type: 'text/plain', href: artifacts.index, title: `${product.title} documentation index` },
    { rel: 'describedby', type: 'application/json', href: artifacts.json, title: `${product.title} documentation manifest` },
    { rel: 'describedby', type: 'text/markdown', href: `${docsHome(doc.product)}/AGENTS.md`, title: `${product.title} agent instructions` },
  ]
}

interface DocMetadata {
  title: string
  description?: string
  /** A source-derived timestamp, never the build time. */
  updatedAt?: string | null
}

/** Accept only complete ISO dates/timestamps; unknown dates are omitted. */
export function sourceDate(value: string | null | undefined): string | undefined {
  if (!value || !/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))?$/.test(value)) return undefined
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return undefined
  // Date.parse normalizes invalid dates such as February 30.
  const day = value.slice(0, 10)
  if (new Date(`${day}T00:00:00Z`).toISOString().slice(0, 10) !== day) return undefined
  return value
}

/** Shared by static HTML and client navigation so product identity cannot drift. */
export function docJsonLd(doc: DocEntry, metadata: DocMetadata): string {
  if (!doc.canonicalPath) throw new Error(`Cannot describe an unpublished document: ${doc.id}`)
  const product = docsProduct(doc.product)
  const overview = publishedDocs.find((entry) => entry.product === doc.product && entry.slug === 'overview')!
  const url = absoluteUrl(doc.canonicalPath)
  const home = absoluteUrl(overview.canonicalPath!)
  const pageId = `${url}#webpage`
  const collectionId = `${home}#webpage`
  const productUrl = absoluteUrl(product.home)
  const productId = `${productUrl}#software`
  const isOverview = doc.id === overview.id
  const modified = sourceDate(metadata.updatedAt)
  const current = isCurrentDoc(doc)
  const description = metadata.description || product.description
  const breadcrumbs = [
    { name: 'Lattices', item: absoluteUrl('/') },
    ...(product.home !== '/' ? [{ name: product.title, item: productUrl }] : []),
    { name: `${product.title} documentation`, item: home },
    ...(!isOverview ? [{ name: metadata.title, item: url }] : []),
  ]
  const collection = {
    '@type': 'CollectionPage',
    '@id': collectionId,
    url: home,
    name: `${product.title} documentation`,
    isPartOf: { '@id': `${SITE_ORIGIN}/#website` },
    about: { '@id': productId },
    inLanguage: 'en',
  }
  const page = {
    ...(isOverview ? collection : {
      '@type': 'WebPage', '@id': pageId, url,
      name: `${metadata.title} — ${product.title} Docs`,
      isPartOf: { '@id': collectionId },
      about: { '@id': productId },
      inLanguage: 'en',
    }),
    description,
    breadcrumb: { '@id': `${url}#breadcrumbs` },
    mainEntity: { '@id': `${url}#article` },
    ...(modified ? { dateModified: modified } : {}),
    ...(isOverview ? {
      hasPart: publishedDocs
        .filter((entry) => entry.product === doc.product && entry.id !== doc.id && isCurrentDoc(entry))
        .map((entry) => ({ '@type': 'WebPage', '@id': `${absoluteUrl(entry.canonicalPath!)}#webpage`, name: entry.title, url: absoluteUrl(entry.canonicalPath!) })),
    } : {}),
  }
  const graph = [
    { '@type': 'WebSite', '@id': `${SITE_ORIGIN}/#website`, name: 'Lattices', url: absoluteUrl('/') },
    { '@type': 'SoftwareApplication', '@id': productId, name: product.title, description: product.description, url: productUrl },
    ...(!isOverview ? [collection] : []),
    page,
    {
      '@type': current ? 'TechArticle' : 'Article',
      '@id': `${url}#article`,
      headline: metadata.title,
      description,
      url,
      mainEntityOfPage: { '@id': pageId },
      isPartOf: { '@id': collectionId },
      about: { '@id': productId },
      inLanguage: 'en',
      articleSection: current ? `${product.title} documentation` : `${product.title} archive: ${doc.kind}`,
      ...(modified ? { dateModified: modified } : {}),
      encoding: { '@type': 'MediaObject', encodingFormat: 'text/markdown', contentUrl: absoluteUrl(docMarkdownUrl(doc.canonicalPath)) },
    },
    {
      '@type': 'BreadcrumbList', '@id': `${url}#breadcrumbs`,
      itemListElement: breadcrumbs.map((item, index) => ({ '@type': 'ListItem', position: index + 1, ...item })),
    },
  ]
  // The result is embedded in HTML script elements by both renderers.
  return JSON.stringify({ '@context': 'https://schema.org', '@graph': graph }).replace(/</g, '\\u003c')
}
