import { useEffect, useState } from 'react'
import { defaultDoc, getDoc, type DocPage } from '../lib/content'
import { formatBuildDate, getBuildMeta, type DocMeta } from '../lib/build-meta'
import { MarkdownRenderer } from './MarkdownRenderer'
import { DocsSidebar, DocPager } from './DocsNavigation'
import { docsProduct, docsHome, isCurrentDoc, type ProductId } from '../lib/docs-catalog'
import { SiteFooter, SiteHeader } from './SiteChrome'
import { DocsAgentContext } from './DocsAgentContext'
import { sourceDate } from '../seo/docs'

interface DocsPageProps {
  slug?: string
  product: ProductId
}

export function DocsPage({ slug, product }: DocsPageProps) {
  const doc = slug ? getDoc(slug, product) : defaultDoc(product)
  const [meta, setMeta] = useState<DocMeta | null>(null)

  useEffect(() => {
    if (!doc) return
    let cancelled = false
    getBuildMeta().then((m) => {
      if (cancelled) return
      setMeta(m?.docs?.[doc.id] ?? null)
    })
    return () => {
      cancelled = true
    }
  }, [doc])

  if (!doc) {
    return (
      <div className="docs-page">
        <SiteHeader docsProductId={product} />
        <main className="not-found-shell" data-pagefind-ignore>
          <div className="not-found-card">
            <p className="not-found-kicker">404</p>
            <h1 className="not-found-title">Page not found</h1>
            <p className="not-found-desc">
              The docs page may have been moved.{' '}
              <a href={docsHome(product)}>Back to the docs overview →</a>
            </p>
          </div>
        </main>
        <SiteFooter />
      </div>
    )
  }

  const updatedAt = sourceDate(meta?.updatedAt)
  const updatedLabel = formatBuildDate(updatedAt)

  return (
    <div className="docs-page">
      <SiteHeader docsProductId={product} />
      <main className="docs-shell" data-pagefind-body={isCurrentDoc(doc) ? true : undefined} data-pagefind-ignore={!isCurrentDoc(doc) ? true : undefined}>
        <aside className="docs-sidebar" data-pagefind-ignore>
          <DocsSidebar key={doc.id} product={product} currentSlug={doc.slug} />
        </aside>
        <article className="docs-article" aria-labelledby="doc-title">
          <header className="docs-article-header">
            <a className="docs-product-home" href={docsHome(product)}>{docsProduct(product).title} documentation</a>
            <h1 id="doc-title">{doc.title}</h1>
            {doc.description && <p>{doc.description}</p>}
            <div className="docs-meta">
              {updatedLabel && <span>Updated <time dateTime={updatedAt}>{updatedLabel}</time></span>}
              {meta?.editUrl && (
                <a
                  href={meta.editUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  Edit on GitHub →
                </a>
              )}
              <DocsAgentContext key={doc.id} doc={doc} product={product} />
            </div>
          </header>
          {!isCurrentDoc(doc) && (
            <p className="docs-status-notice">Archived {doc.kind}. This document records a proposal or past work and is not current product guidance. <a href={docsHome(product)}>Read the current {docsProduct(product).title} docs.</a></p>
          )}
          <MarkdownRenderer content={doc.content} />
          <DocPager product={product} currentSlug={doc.slug} />
        </article>
        <aside className="docs-toc" data-pagefind-ignore>
          <TableOfContents doc={doc} />
        </aside>
      </main>
      <SiteFooter current={doc.canonicalPath!} />
    </div>
  )
}

/** Tracks the heading nearest the top of the viewport for the on-this-page rail. */
function useActiveHeading(ids: string[]): string | null {
  const [active, setActive] = useState<string | null>(ids[0] ?? null)
  const key = ids.join('|')

  useEffect(() => {
    const list = key ? key.split('|') : []
    if (list.length === 0) return
    let frame = 0
    const update = () => {
      frame = 0
      const offset = 120
      let current = list[0]
      for (const id of list) {
        const el = document.getElementById(id)
        if (!el) continue
        if (el.getBoundingClientRect().top - offset <= 0) current = id
        else break
      }
      const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4
      setActive(atBottom ? list[list.length - 1] : current)
    }
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(update)
    }
    update()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      if (frame) cancelAnimationFrame(frame)
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
    }
  }, [key])

  return active
}

function TableOfContents({ doc }: { doc: DocPage }) {
  const headings = doc.headings.filter((heading) => heading.depth >= 2 && heading.depth <= 3)
  const active = useActiveHeading(headings.map((heading) => heading.id))

  if (headings.length === 0) return null

  return (
    <nav className="toc-nav" aria-label="On this page">
      <p>On this page</p>
      <ul>
        {headings.map((heading) => (
          <li key={heading.id} className={heading.depth === 3 ? 'nested' : undefined}>
            <a
              href={`#${heading.id}`}
              className={active === heading.id ? 'active' : undefined}
              aria-current={active === heading.id ? 'location' : undefined}
            >
              {heading.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  )
}
